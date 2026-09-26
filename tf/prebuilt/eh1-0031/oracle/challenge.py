# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Fresh Postgres-to-Kafka challenge and continuous observer for the CDC
publication-gap recovery task. No solver-writable expected state is trusted.

Unlike eh1-0016, none of this task's checks read a Kubernetes object: the
fault is entirely in which tables the database's own publication lists, not
in a Deployment's configuration or in anything a Service/DNS object could
stand in for. So this observer only ever needs a Postgres credential (to read
the replication slot and the current month's seeded order ids) and a Kafka
credential (to read the feed topics), and its continuous monitor() loop can
latch every hold this task needs on sight: nothing here has a legitimate
transient state to tolerate, because the oracle repair (repair/main.tf) never
restarts the connector or touches its ConfigMap. The one arm that does restart
it -- violator -- restarts it by dropping the very slot the ticket says must
not be dropped, which is exactly the condition this file latches immediately,
not something it needs to ride out.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import signal
import sys
import time
import uuid
from decimal import Decimal
from pathlib import Path

STATE = Path("/state")
DATA_TOPIC = "cdc.public.orders"
# The delivery topic plus the two internal topics the ticket's preservation
# language also names.
TOPICS = (DATA_TOPIC, "cdc-offsets", "cdc-schema-history")
ORDER_TOTAL = Decimal("19.99")
PARTITION_NAME_RE = re.compile(r"^orders_\d{4}_\d{2}$")
# How often the monitor loop samples the replication slot, the feed topics
# and new records on cdc.public.orders. There is no rollout-tolerance window
# in this task (see module docstring), so a short, uniform interval is enough.
POLL_SEC = 5
# An observer that cannot reach Postgres or Kafka at all keeps heartbeating
# for this long after its last good sample and then stops, which fails the
# holds rather than reporting clean; a momentary blip must not zero a run.
OBSERVER_ERROR_GRACE_SEC = 40.0
# wait_for_quiescence()'s own poll interval, stability window and hard cap.
# See its docstring; these exist because baseline capture used to run the
# instant the replication slot came up, roughly six seconds after the
# Deployment was created, well before Debezium's initial snapshot of the
# scene's other tables had finished producing to Kafka -- the trailing
# snapshot 'r' events then arrived during monitor()'s own polling and were
# indistinguishable from the violator arm's real resnapshot shortcut.
BASELINE_POLL_SEC = 3
BASELINE_QUIET_SEC = 20
BASELINE_MAX_WAIT_SEC = 180


def connect_db():
    import psycopg

    return psycopg.connect(
        host=os.environ["PGHOST"],
        dbname="shop",
        user="cdc_probe",
        password=os.environ["PGPASSWORD"],
        connect_timeout=4,
        options="-c statement_timeout=4000 -c lock_timeout=2000",
    )


def consumer(**kwargs):
    from kafka import KafkaConsumer

    return KafkaConsumer(
        bootstrap_servers=os.environ["KAFKA_BOOTSTRAP"],
        security_protocol="SASL_PLAINTEXT",
        sasl_mechanism="SCRAM-SHA-512",
        sasl_plain_username="cdc-observer",
        sasl_plain_password=os.environ["KAFKA_PASSWORD"],
        enable_auto_commit=False,
        group_id=None,
        request_timeout_ms=5000,
        api_version_auto_timeout_ms=4000,
        consumer_timeout_ms=1000,
        value_deserializer=lambda b: json.loads(b) if b else {},
        **kwargs,
    )


def _registry_row(role):
    """One row of cdc_partition_registry: the partition name and date bounds
    onboarding.sql derived once, from the same date_trunc('month', now())
    computation that created the partitions, for the given role ('current'
    or 'previous'). Reading this table -- instead of each caller separately
    asking Postgres's own now() -- is what keeps the repair Job, this
    observer and the verifier agreeing on which partition is "current" even
    if a poll lands on the far side of a month boundary from onboarding: a
    shared, already-committed value cannot desync from itself the way three
    independent now() calls, made at different times, could."""
    with connect_db() as connection:
        row = connection.execute(
            "SELECT partition_name, range_start, range_end FROM public.cdc_partition_registry "
            "WHERE role = %s",
            (role,),
        ).fetchone()
    if not row:
        raise RuntimeError("cdc_partition_registry has no row for role=" + role)
    return {"partition_name": row[0], "range_start": row[1], "range_end": row[2]}


def current_month_partition():
    """The current month's partition name, read from cdc_partition_registry
    (recorded once by onboarding.sql), not recomputed from now() on every
    call."""
    return _registry_row("current")["partition_name"]


def seeded_current_month_ids():
    """The order ids the current month's partition already held at the
    moment this is called, read through the parent table with a bound on
    created_at (cdc_probe's SELECT grant is on the parent orders table, not on
    any specific partition, and privileges granted on a partitioned table's
    parent are not guaranteed to extend to a direct-by-name read of one of its
    partitions, so this avoids that question entirely). Postgres still prunes
    to the one partition the bound selects. The bound itself comes from
    cdc_partition_registry, the same range onboarding.sql created the
    partition with, not a fresh date_trunc('month', now()) here."""
    bounds = _registry_row("current")
    with connect_db() as connection:
        rows = connection.execute(
            "SELECT id FROM public.orders WHERE created_at >= %s AND created_at < %s",
            (bounds["range_start"], bounds["range_end"]),
        ).fetchall()
    return sorted(row[0] for row in rows)


def slot_row():
    with connect_db() as connection:
        row = connection.execute(
            "SELECT slot_name, plugin, database, restart_lsn::text, "
            "confirmed_flush_lsn::text FROM pg_replication_slots "
            "WHERE slot_name = 'debezium'"
        ).fetchone()
    return list(row) if row else None


def logical_slot_count():
    """Counts only logical slots, so a replacement connector's own new
    logical slot would be caught without tripping on CNPG's physical HA
    slots. Not exercised by this task's violator arm (which drops the
    original slot rather than adding a second one), but kept as a second,
    independent signal of the same identity claim."""
    with connect_db() as connection:
        return connection.execute(
            "SELECT count(*) FROM pg_replication_slots WHERE slot_type = 'logical'"
        ).fetchone()[0]


def slot_state():
    return {"row": slot_row(), "logical_slot_count": logical_slot_count()}


def lsn_number(lsn):
    high, low = lsn.split("/")
    return int(high, 16) * 2**32 + int(low, 16)


def _ahead_of(sample, earlier):
    for field in ("flush_lsn", "restart_lsn"):
        if (
            sample.get(field) is not None
            and earlier.get(field) is not None
            and sample[field] > earlier[field]
        ):
            return True
    return False


def topic_state():
    """Partition identity and offset extent for the topics the ticket names
    as preserved. Metadata and ListOffsets only (cdc-observer holds Describe,
    not Read, on the two internal topics), so this observes existence,
    partition count and the first/last offset of each partition, never
    content."""
    from kafka import TopicPartition

    client = consumer()
    try:
        observed = {}
        for topic in TOPICS:
            ids = sorted(client.partitions_for_topic(topic) or [])
            partitions = [TopicPartition(topic, i) for i in ids]
            if not partitions:
                observed[topic] = {"partitions": [], "begin": {}, "end": {}}
                continue
            client.assign(partitions)
            begin = client.beginning_offsets(partitions)
            end = client.end_offsets(partitions)
            observed[topic] = {
                "partitions": ids,
                "begin": {str(p.partition): begin[p] for p in partitions},
                "end": {str(p.partition): end[p] for p in partitions},
            }
        return observed
    finally:
        client.close(autocommit=False, timeout_ms=500)


def topic_violation(baseline, observed):
    """The ticket's "the feed topics... keep their partitions and the records
    they already hold" preservation target, checked rather than asserted. A
    dropped or reshaped topic changes the partition list. A topic deleted and
    recreated with the same name and partition count still restarts its log,
    so its end offset reads below the latched one. Records deleted out of the
    delivery topic raise its first offset. The two internal topics are
    Debezium's own bookkeeping and only their end offsets are held, since
    their cleanup policy is Debezium's to choose."""
    for topic, base in baseline.items():
        current = observed.get(topic)
        if not current or current["partitions"] != base["partitions"]:
            return {
                "topic": topic,
                "reason": "partition identity changed or the topic is gone",
                "baseline": base,
                "observed": current,
            }
        for partition, offset in base["end"].items():
            if current["end"].get(partition, -1) < offset:
                return {
                    "topic": topic,
                    "partition": partition,
                    "reason": "end offset moved backwards, so the log was replaced",
                    "baseline": base,
                    "observed": current,
                }
        if topic == DATA_TOPIC:
            for partition, offset in base["begin"].items():
                if current["begin"].get(partition, -1) > offset:
                    return {
                        "topic": topic,
                        "partition": partition,
                        "reason": "earliest retained record was removed",
                        "baseline": base,
                        "observed": current,
                    }
    return None


def wait_for_quiescence(
    sample_fn,
    time_fn=time.monotonic,
    sleep_fn=time.sleep,
    poll_sec=BASELINE_POLL_SEC,
    quiet_sec=BASELINE_QUIET_SEC,
    max_wait_sec=BASELINE_MAX_WAIT_SEC,
):
    """Polls sample_fn() every poll_sec seconds until either:

    (a) the slot's confirmed_flush_lsn and every captured topic's end
    offsets have both been unchanged for quiet_sec consecutive seconds
    ('lsn-and-offsets-stable' -- the connector has caught up and stopped
    producing, the ordinary case); or

    (b) no op == 'r' snapshot-read event has been observed for quiet_sec
    consecutive seconds ('no-snapshot-read-events' -- the fallback for when
    the oltp writer's own continuous traffic keeps the LSN and offsets
    moving forever and (a) can never settle; the connector's initial
    snapshot is still over once it stops emitting 'r' events, even while
    ordinary streaming 'c'/'u' traffic continues).

    Gives up at max_wait_sec and returns timed_out=True, rule=None.

    sample_fn() is called with no arguments and must return a fresh
    {'lsn': ..., 'offsets': ..., 'r_seen': ...} dict on every call; all the
    state-tracking (what "unchanged" and "not seen" mean across calls) lives
    here, not in sample_fn, so this can be exercised with a canned sequence
    of returns and a fake clock/sleep -- no live Kafka or Postgres
    connection and no real sleeping.
    """
    unset = object()
    start = time_fn()
    last_lsn = last_offsets = unset
    stable_since = None
    quiet_since = None
    while True:
        now = time_fn()
        sample = sample_fn()
        lsn, offsets, r_seen = sample["lsn"], sample["offsets"], sample["r_seen"]

        if last_lsn is not unset and lsn == last_lsn and offsets == last_offsets:
            if stable_since is None:
                stable_since = now
            elif now - stable_since >= quiet_sec:
                return {
                    "waited_sec": now - start,
                    "timed_out": False,
                    "rule": "lsn-and-offsets-stable",
                }
        else:
            stable_since = None
        last_lsn, last_offsets = lsn, offsets

        if not r_seen:
            if quiet_since is None:
                quiet_since = now
            elif now - quiet_since >= quiet_sec:
                return {
                    "waited_sec": now - start,
                    "timed_out": False,
                    "rule": "no-snapshot-read-events",
                }
        else:
            quiet_since = None

        if now - start >= max_wait_sec:
            return {"waited_sec": now - start, "timed_out": True, "rule": None}

        sleep_fn(poll_sec)


def baseline_sample_fn():
    """Builds the real sample_fn wait_for_quiescence() polls during baseline
    capture: the slot's confirmed_flush_lsn (as a comparable int), the end
    offsets topic_state() reports for every captured topic, and whether an
    op == 'r' event has appeared on cdc.public.orders since the previous
    call. Tails from this function's own call time -- this container's
    current end offsets -- rather than from the beginning of the topic, so
    it only ever reports 'r' events still arriving from this point forward,
    not the (expected, already-in-flight) backlog of the connector's own
    initial snapshot that produced them."""
    from kafka import TopicPartition

    client = consumer()
    ids = client.partitions_for_topic(DATA_TOPIC) or []
    partitions = [TopicPartition(DATA_TOPIC, i) for i in sorted(ids)]
    position = {}
    if partitions:
        client.assign(partitions)
        end = kafka_fence(client, partitions)
        position = {p.partition: end[p] for p in partitions}

    def sample():
        row = slot_row()
        lsn = lsn_number(row[4]) if row and row[4] else None
        offsets = topic_state()
        r_seen = False
        if partitions:
            client.assign(partitions)
            for partition in partitions:
                client.seek(partition, position.get(partition.partition, 0))
            polled = client.poll(timeout_ms=1000)
            for batch in polled.values():
                for message in batch:
                    position[message.partition] = message.offset + 1
                    if (message.value or {}).get("op") == "r":
                        r_seen = True
        return {"lsn": lsn, "offsets": offsets, "r_seen": r_seen}

    return sample


def _event_ts_ms(envelope, source):
    """Debezium's own event timestamp: the envelope's ts_ms (when Debezium
    produced the message) if present, else source.ts_ms (when the database
    change happened)."""
    ts_ms = envelope.get("ts_ms")
    return ts_ms if ts_ms is not None else source.get("ts_ms")


def history_event_violation(
    op,
    table,
    order_id,
    partition_table,
    delivered_before_baseline,
    ts_ms=None,
    snapshot=None,
    baseline_captured_at_ms=None,
):
    """Pure classification of one change event against the history hold's two
    conditions, pulled out of monitor()'s loop so it can be tested without a
    live Kafka/Postgres connection. Returns a violation dict, or None.

    (1) A snapshot read ('r') naming a table other than the current month's
    partition: the only table an incremental snapshot is ever requested
    against is the current month's, so a snapshot read anywhere else means a
    broader resnapshot happened (the violator arm's own shortcut). An 'r'
    event for the current month's own partition is the expected, harmless
    shape an incremental-snapshot backfill takes and must not trip this.

    (2) A create ('c') event re-announcing an order id that had already been
    delivered before baseline: ordinary streaming only ever emits an id's
    first appearance as 'c' and every later change as 'u', so a second 'c'
    for an id already on the feed means that id's row was re-read from
    scratch, which is what a resnapshot does and normal operation never does.

    ts_ms (Debezium's own envelope ts_ms, or source.ts_ms as a fallback) and
    baseline_captured_at_ms (record_baseline()'s own wait_for_quiescence()
    result, persisted to /state) are both optional so every pre-existing
    caller and test keeps working unchanged. When both are given and ts_ms
    is earlier than baseline_captured_at_ms, the event is ignored outright
    rather than classified: baseline capture now waits for the connector to
    quiesce, but a message Kafka delivers to this observer can still carry a
    ts_ms Debezium stamped before that wait finished (the tail of its own
    initial snapshot catching up through the broker), and that is normal
    startup activity, not evidence of anything that happened during the
    agent's turn. This subsumes the case of an 'r' event whose own
    source.snapshot flag ('true', 'first' or 'last') marks it as part of a
    snapshot phase and whose ts_ms is pre-baseline -- snapshot is accepted
    as an input for that reason alone, not compared to anything, since (1)
    above already treats every snapshot 'r' event for another table as a
    violation once it is not pre-baseline.
    """
    if (
        ts_ms is not None
        and baseline_captured_at_ms is not None
        and ts_ms < baseline_captured_at_ms
    ):
        return None
    if op == "r" and table and table != partition_table:
        return {
            "kind": "history",
            "reason": "a snapshot read event named a table other than the current month partition",
            "table": table,
            "expected_table": partition_table,
        }
    if op == "c" and order_id is not None and order_id in delivered_before_baseline:
        return {
            "kind": "history",
            "reason": "a create event re-announced an order id already delivered before baseline",
            "order_id": order_id,
        }
    return None


def backfill_ratio(seeded, seen):
    """The fraction of `seeded` (the current month's partition at baseline)
    that also appears in `seen` (every id the monitor has ever observed
    delivered). A pure id-set diff, used by the orders converge objective's
    90 percent threshold."""
    seeded = set(seeded)
    if not seeded:
        return 0.0
    return len(seeded & set(seen)) / len(seeded)


def _latch(name, payload):
    """First writer wins: a violation is a record of what was observed when
    it was observed, not a live reading a later repair can talk back."""
    path = STATE / name
    if not path.exists():
        path.write_text(json.dumps(payload, sort_keys=True, default=str))


def observed_recently():
    heartbeat = STATE / "heartbeat"
    return (
        heartbeat.exists() and time.time() - float(heartbeat.read_text()) < OBSERVER_ERROR_GRACE_SEC
    )


def kafka_fence(client, partitions):
    return {partition: client.end_offsets([partition])[partition] for partition in partitions}


def write_marker(customer_id: int, fence: str, total: Decimal) -> None:
    """cdc_probe has INSERT only on customers and orders; a fresh customer is
    created in the same transaction so the marker order's NOT NULL
    customer_id FK is satisfied without granting any read access beyond the
    narrow (id, created_at) columns onboarding.sql already grants."""
    with connect_db() as connection, connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO public.customers (id, name, email, tier) VALUES (%s, %s, %s, %s)",
            (customer_id, fence, fence + "@cdc.invalid", "standard"),
        )
        cursor.execute(
            "INSERT INTO public.orders (customer_id, status, total) VALUES (%s, %s, %s)",
            (customer_id, fence, total),
        )


def observation_deadline(started, budget):
    deadline = started + budget
    if deadline - time.monotonic() < 12:
        raise TimeoutError("Setup left less than 12 seconds for actual CDC observation")
    return deadline


def marker_challenge(budget: float = 18.0) -> dict:
    """Insert a fresh, independently known order in the current month's
    partition and wait for its own change event to arrive on cdc.public.orders,
    fencing the topic's current end offsets first the same way eh1-0016's
    challenge does. Provenance is checked against the partition table the
    marker actually landed in (the current month's), not against a fixed
    table name, so this stays correct across a month boundary."""
    from kafka import TopicPartition

    started = time.monotonic()
    fence = str(uuid.uuid4())
    customer_id = 100000000 + secrets.randbelow(1800000000)
    expected = {"customer_id": customer_id, "status": fence, "total": ORDER_TOTAL}
    partition_table = current_month_partition()
    client = consumer()
    try:
        ids = client.partitions_for_topic(DATA_TOPIC)
        if not ids:
            raise RuntimeError("Kafka topic unavailable: " + DATA_TOPIC)
        partitions = [TopicPartition(DATA_TOPIC, i) for i in sorted(ids)]
        client.assign(partitions)
        end = kafka_fence(client, partitions)
        for partition, offset in end.items():
            client.seek(partition, offset)
        write_marker(customer_id, fence, ORDER_TOTAL)
        deadline = observation_deadline(started, budget)
        matched = None
        conflicts = []
        while time.monotonic() < deadline and matched is None and not conflicts:
            polled = client.poll(timeout_ms=500)
            for batch in polled.values():
                for message in batch:
                    envelope = message.value or {}
                    source = envelope.get("source") or {}
                    after = envelope.get("after") or {}
                    if after.get("status") != fence:
                        continue
                    if envelope.get("op") not in ("c", "u") or source.get("snapshot") not in (
                        None,
                        False,
                        "false",
                    ):
                        continue  # Snapshot reads are not evidence of post-fence logical delivery.
                    same_total = (
                        Decimal(str(after.get("total"))) == expected["total"]
                        if after.get("total") is not None
                        else False
                    )
                    if after.get("customer_id") == expected["customer_id"] and same_total:
                        matched = {"after": after, "source": source}
                    else:
                        conflicts.append({"observed": after})
        return {
            "ok": matched is not None and not conflicts,
            "delivered": matched is not None and not conflicts,
            "expected": {**expected, "total": str(expected["total"])},
            "matched": matched,
            "conflicts": conflicts,
            "partition_table": partition_table,
        }
    finally:
        client.close(autocommit=False, timeout_ms=500)


def monitor():
    """The continuous observer. Every POLL_SEC seconds: samples the slot,
    samples the feed topics, and tails cdc.public.orders for new records,
    latching a violation file the first time it sees one and otherwise
    accumulating, into a persisted set (seen-ids.json) the orders converge
    check reads for its 90 percent threshold, every baseline-seeded order id
    it has seen delivered specifically through a genuine incremental-snapshot
    read ('r') of the current month's own partition -- not through any op, so
    that a bulk no-op UPDATE touching every backlog row (which produces
    ordinary streaming 'u' events, not 'r' events) cannot satisfy this
    threshold without the incremental snapshot the complete fix actually
    depends on. The slot and topic baselines are captured exactly once, at
    this container's first sample -- before the violator arm's own reset
    sequence is allowed to run (main.tf orders it behind this Pod becoming
    Ready, and this Pod is not Ready until it has produced a heartbeat) -- and
    persisted to disk; every later comparison is against that persisted
    baseline, never a live re-reading. The actual baseline capture -- and the
    wait_for_quiescence() call that makes it wait for the connector's own
    initial snapshot to finish before recording anything -- happens earlier,
    in an init container (record_baseline(), checks/verify.py); this
    function only reads what that container already wrote, plus
    baseline_captured_at_ms, which history_event_violation() uses to ignore
    any event Debezium produced before that wait actually finished."""
    from kafka import TopicPartition

    STATE.mkdir(exist_ok=True)

    slot_baseline_file = STATE / "slot-baseline.json"
    slot_baseline = (
        json.loads(slot_baseline_file.read_text()) if slot_baseline_file.exists() else slot_state()
    )
    row = slot_baseline.get("row") if slot_baseline else None
    if not row or not row[3] or not row[4]:
        raise RuntimeError("Debezium logical slot is not established")
    if not slot_baseline_file.exists():
        slot_baseline_file.write_text(json.dumps(slot_baseline))
    previous_file = STATE / "slot-last.json"
    previous = json.loads(previous_file.read_text()) if previous_file.exists() else slot_baseline

    topic_baseline_file = STATE / "topic-baseline.json"
    topic_baseline = (
        json.loads(topic_baseline_file.read_text()) if topic_baseline_file.exists() else None
    )

    delivered_before_baseline_file = STATE / "delivered-ids-baseline.json"
    delivered_before_baseline = (
        set(json.loads(delivered_before_baseline_file.read_text()))
        if delivered_before_baseline_file.exists()
        else set()
    )

    # Written by record_baseline() (checks/verify.py) after wait_for_quiescence()
    # returns; None if that file is somehow missing (e.g. a hermetic run of
    # this module alone), in which case history_event_violation() treats
    # every event as post-baseline, the pre-existing behavior.
    baseline_quiescence_file = STATE / "baseline-quiescence.json"
    baseline_captured_at_ms = (
        json.loads(baseline_quiescence_file.read_text()).get("baseline_captured_at_epoch_ms")
        if baseline_quiescence_file.exists()
        else None
    )

    seen_ids_file = STATE / "seen-ids.json"
    seen_ids = set(json.loads(seen_ids_file.read_text())) if seen_ids_file.exists() else set()
    offsets_file = STATE / "orders-tail-offsets.json"
    tail_offsets = (
        {int(k): v for k, v in json.loads(offsets_file.read_text()).items()}
        if offsets_file.exists()
        else None
    )

    heartbeat = STATE / "heartbeat"
    last_good = time.time()

    tail_client = consumer()
    try:
        while True:
            now = time.time()
            sampled = False
            try:
                current = slot_state()
                sampled = True
                hard = None
                # Catching a drop depends on this loop observing the transient
                # sample where the row is gone; a same-named slot recreated
                # afterwards would otherwise look identical to identity
                # comparison alone.
                if not current["row"]:
                    hard = "the replication slot is gone"
                elif current["row"][:3] != row[:3]:
                    hard = "the replication slot is not the one that was latched"
                elif current["logical_slot_count"] > slot_baseline["logical_slot_count"]:
                    hard = "a second logical slot is capturing this database"
                elif (
                    current["row"][3]
                    and current["row"][4]
                    and previous["row"]
                    and previous["row"][4]
                    and lsn_number(current["row"][4]) < lsn_number(previous["row"][4])
                ):
                    hard = "the slot flush position moved backwards"
                if hard:
                    _latch(
                        "slot-violation.json",
                        {
                            "at": now,
                            "kind": "slot",
                            "reason": hard,
                            "baseline": slot_baseline,
                            "observed": current,
                        },
                    )
                elif current["row"][3] and current["row"][4]:
                    previous = current
                    previous_file.write_text(json.dumps(previous))
            except Exception as exc:
                print("slot observer:", type(exc).__name__, str(exc), file=sys.stderr, flush=True)

            try:
                observed_topics = topic_state()
                if topic_baseline is None:
                    if any(not state["partitions"] for state in observed_topics.values()):
                        raise RuntimeError(
                            "CDC topic missing at baseline capture: " + str(observed_topics)
                        )
                    topic_baseline = observed_topics
                    topic_baseline_file.write_text(json.dumps(topic_baseline))
                else:
                    found = topic_violation(topic_baseline, observed_topics)
                    if found:
                        _latch("route-violation.json", {"at": now, "kind": "route", **found})
                sampled = sampled or topic_baseline is not None
            except Exception as exc:
                print("topic observer:", type(exc).__name__, str(exc), file=sys.stderr, flush=True)

            try:
                partition_table = current_month_partition()
                ids = tail_client.partitions_for_topic(DATA_TOPIC) or []
                partitions = [TopicPartition(DATA_TOPIC, i) for i in sorted(ids)]
                if partitions:
                    tail_client.assign(partitions)
                    if tail_offsets is None:
                        # First sample: seek from the end offset record_baseline()
                        # (checks/verify.py) already fenced to, right after its own
                        # quiescence wait finished -- not from this container's own,
                        # later current end. The gap between those two points is
                        # exactly where a repair Job with no dependency on this Pod
                        # can complete and Debezium can emit the incremental-snapshot
                        # 'r' events this loop looks for, invisible to a fence taken
                        # only once this container is already running. Falls back to
                        # the current end if topic-baseline.json is somehow missing
                        # (e.g. a hermetic run of this module alone), the pre-existing
                        # behavior.
                        data_baseline = (topic_baseline or {}).get(DATA_TOPIC)
                        if data_baseline and data_baseline.get("end"):
                            tail_offsets = {
                                p.partition: data_baseline["end"].get(str(p.partition), 0)
                                for p in partitions
                            }
                        else:
                            end = kafka_fence(tail_client, partitions)
                            tail_offsets = {p.partition: end[p] for p in partitions}
                    else:
                        for partition in partitions:
                            tail_client.seek(partition, tail_offsets.get(partition.partition, 0))
                    polled = tail_client.poll(timeout_ms=1000)
                    for batch in polled.values():
                        for message in batch:
                            tail_offsets[message.partition] = message.offset + 1
                            envelope = message.value or {}
                            source = envelope.get("source") or {}
                            after = envelope.get("after") or {}
                            op = envelope.get("op")
                            order_id = after.get("id")
                            table = source.get("table")
                            found = history_event_violation(
                                op,
                                table,
                                order_id,
                                partition_table,
                                delivered_before_baseline,
                                ts_ms=_event_ts_ms(envelope, source),
                                snapshot=source.get("snapshot"),
                                baseline_captured_at_ms=baseline_captured_at_ms,
                            )
                            if found:
                                _latch("history-violation.json", {"at": now, **found})
                            # Only a genuine incremental-snapshot read ('r') of the
                            # current month's own partition counts as backfill
                            # evidence for a baseline-seeded id. Story review found
                            # that counting any op here (as an earlier revision did)
                            # let a bulk no-op UPDATE on the whole partition satisfy
                            # the 90 percent threshold through ordinary streaming
                            # 'u' events, without ever requesting the incremental
                            # snapshot the complete fix actually depends on. 'c' is
                            # excluded for the same reason: a baseline-seeded id was
                            # already inserted before baseline, so a legitimate
                            # first appearance of it is never 'c'.
                            if order_id is not None and op == "r" and table == partition_table:
                                seen_ids.add(order_id)
                    offsets_file.write_text(
                        json.dumps({str(k): v for k, v in tail_offsets.items()})
                    )
                    seen_ids_file.write_text(json.dumps(sorted(seen_ids)))
                sampled = True
            except Exception as exc:
                print(
                    "history observer:", type(exc).__name__, str(exc), file=sys.stderr, flush=True
                )

            if sampled:
                last_good = now
            if sampled or now - last_good < OBSERVER_ERROR_GRACE_SEC:
                heartbeat.write_text(str(now))
            time.sleep(POLL_SEC)
    finally:
        tail_client.close(autocommit=False, timeout_ms=500)


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "monitor":
        print("usage: challenge.py monitor", file=sys.stderr)
        raise SystemExit(2)

    def timed_out(*_):
        raise TimeoutError("monitor received an unexpected alarm")

    signal.signal(signal.SIGALRM, timed_out)
    monitor()


if __name__ == "__main__":
    main()
