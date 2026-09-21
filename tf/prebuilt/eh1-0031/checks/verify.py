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

"""The verification the four entries in task.yaml actually run.

This file is not part of the oracle image. It is carried into the verifier Pod
as a Secret and mounted read-only at /checks (oracle.tf), for the same two
reasons eh1-0016 gives: the oracle image is content-hash pinned, so adding
verification there means rebuilding and republishing it, and module.bench_agent's
cluster_read grant binds the built-in view ClusterRole, which reads ConfigMaps
and reads no Secret anywhere.

Everything reusable is imported from /oracle/challenge.py rather than
restated: the fenced marker-order challenge, the continuous monitor's own
latched verdicts (slot-violation.json, route-violation.json,
history-violation.json), its persisted baselines and its heartbeat.

Modes: baseline (records the slot, topic and delivered-id baselines this
task's holds and converge objective read; not a check, run once from an init
container before the agent's turn begins), slot and route (holds reusing
challenge.py's own slot/topic logic almost unchanged from eh1-0016), history
(a hold this task adds: no snapshot-read event names a table other than the
current month's partition, and no create event re-announces an order id
already delivered before baseline), and orders (the converge objective: a
fresh marker order is delivered, and at least 90 percent of the ids the
current month's partition held at baseline have been delivered by now).

Unlike eh1-0016, no hold here needs a rollout-tolerance window. The oracle
repair (repair/main.tf) is pure SQL against the database; it never restarts
the debezium-server Deployment or touches its ConfigMap, so there is no
legitimate path in this task on which a hold's own condition could appear
transiently. The one arm that does restart the connector -- violator -- does
so by dropping the very replication slot the ticket says must survive, which
is exactly what the slot hold is watching for: the restart is not something
to tolerate, it is the mechanism of the shortcut itself. Every hold here
therefore latches on the first sample that sees a genuine violation (via
challenge.py's own first-writer-wins _latch()) rather than requiring a streak
of consecutive samples the way eh1-0016's rollout-aware holds do.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
import time
from datetime import UTC, datetime

sys.path.insert(0, "/oracle")

import challenge as core  # noqa: E402

STATE = core.STATE
SEEDED_IDS = STATE / "seeded-current-month-ids.json"
DELIVERED_BASELINE = STATE / "delivered-ids-baseline.json"
SEEN_IDS = STATE / "seen-ids.json"
BASELINE_QUIESCENCE = STATE / "baseline-quiescence.json"

# Hard budgets, inside the harness's own per-call timeout (a converging entry
# gets min(120, remaining) seconds and re-runs within it; task.yaml's holds
# are safeguards sampled with no window of their own).
ORDERS_BUDGET_SEC = 40.0
GATE_BUDGET_SEC = 20.0
DELIVERY_BUDGET_SEC = 18.0
# record_baseline()'s own quiescence wait (core.wait_for_quiescence()) can
# run up to core.BASELINE_MAX_WAIT_SEC (180s) before falling back; this
# budget has to cover that plus the slot/topic/delivered-id scans that
# follow it, with margin. The incident this exists for: baseline used to be
# captured about six seconds after the Debezium Deployment was created,
# before its initial snapshot of the scene's other tables had finished, and
# the trailing snapshot 'r' events that arrived afterward tripped the
# history hold as if a resnapshot had happened.
BASELINE_BUDGET_SEC = 210.0
# The fraction of the current month's seeded order ids (as of baseline) that
# must have been delivered, specifically through a genuine incremental-snapshot
# read of the current month's own partition, by the time the converge
# objective is checked (challenge.py's monitor() only ever adds an id to
# seen-ids.json on an 'r' event for that partition; see its own docstring).
# 0.9 rather than 1.0 is deliberate: it is what separates "added the current
# month's partition to the publication" (the marker flows; the month's
# earlier orders never do, since streaming alone never re-announces rows it
# never saw) from the complete fix, which requests the incremental snapshot
# that backfills them. Restricting the count to 'r' events (rather than any
# op) is what stops a bulk no-op UPDATE across every backlog row -- which
# produces ordinary streaming 'u' events and needs no incremental snapshot at
# all -- from satisfying this threshold; story review's first round found
# exactly this hole in an earlier revision that counted any op.
DELIVERY_THRESHOLD = 0.9


def _read_json(path, default=None):
    if not path.exists():
        return default
    try:
        txt = path.read_text().strip()
        return json.loads(txt) if txt else default
    except Exception:
        return default


def prior_month_rows_count() -> int:
    bounds = core._registry_row("previous")
    with core.connect_db() as connection:
        rows = connection.execute(
            "SELECT id FROM public.orders WHERE created_at >= %s AND created_at < %s",
            (bounds["range_start"], bounds["range_end"]),
        ).fetchall()
    return len(rows)


def record_baseline():
    """Capture, once, everything the holds and the converge objective read
    against. Ordered (via oracle.tf) before this Pod is Ready and therefore
    before the agent's turn begins and before the violator arm's own reset
    sequence.

    Waits for the connector to quiesce first (core.wait_for_quiescence()):
    without this, baseline used to be captured the instant the replication
    slot came up, before Debezium's initial snapshot of the scene's other
    tables had finished producing to Kafka, and monitor()'s history hold
    then saw the tail of that normal startup snapshot arrive as 'r' events
    for tables other than the current month's partition -- indistinguishable,
    at the time, from the violator arm's real resnapshot shortcut. The
    instant this wait actually finishes (not when the Pod started, and not
    when the slot first became active) is recorded as baseline_captured_at;
    history_event_violation() uses it to ignore any event Debezium stamped
    before that instant, as a second, independent safeguard against the same
    class of race (Kafka delivery to this observer can still lag a little
    behind the wait's own last sample)."""
    STATE.mkdir(exist_ok=True)
    report = {}

    if not BASELINE_QUIESCENCE.exists():
        quiescence = core.wait_for_quiescence(core.baseline_sample_fn())
        captured_at = time.time()
        BASELINE_QUIESCENCE.write_text(
            json.dumps(
                {
                    **quiescence,
                    "baseline_captured_at": datetime.fromtimestamp(captured_at, tz=UTC).isoformat(),
                    "baseline_captured_at_epoch_ms": int(captured_at * 1000),
                }
            )
        )
    report["quiescence"] = _read_json(BASELINE_QUIESCENCE)

    if not (STATE / "slot-baseline.json").exists():
        slot_baseline = core.slot_state()
        row = slot_baseline.get("row")
        if not row or not row[3] or not row[4]:
            raise RuntimeError("Debezium logical slot is not established at baseline capture")
        (STATE / "slot-baseline.json").write_text(json.dumps(slot_baseline))
    report["slot_baseline"] = _read_json(STATE / "slot-baseline.json")

    if not (STATE / "topic-baseline.json").exists():
        topics = core.topic_state()
        if any(not state["partitions"] for state in topics.values()):
            raise RuntimeError("a CDC topic is missing at baseline capture: " + str(topics))
        (STATE / "topic-baseline.json").write_text(json.dumps(topics))
    report["topic_baseline"] = _read_json(STATE / "topic-baseline.json")

    if not SEEDED_IDS.exists():
        seeded = core.seeded_current_month_ids()
        SEEDED_IDS.write_text(json.dumps(seeded))
    report["seeded_current_month_ids_count"] = len(_read_json(SEEDED_IDS, []))
    report["current_month_partition"] = core.current_month_partition()

    if not DELIVERED_BASELINE.exists():
        seeded_set = set(_read_json(SEEDED_IDS, []))
        delivered = _scan_delivered_ids_so_far() - seeded_set
        DELIVERED_BASELINE.write_text(json.dumps(sorted(delivered)))
    report["delivered_before_baseline_count"] = len(_read_json(DELIVERED_BASELINE, []))

    prior_baseline_file = STATE / "prior-month-rows-baseline.json"
    if not prior_baseline_file.exists():
        prior_count = prior_month_rows_count()
        prior_baseline_file.write_text(json.dumps(prior_count))
    report["prior_month_rows_count"] = _read_json(prior_baseline_file, 0)
    return report


def _scan_delivered_ids_so_far():
    """Every order id that has already reached cdc.public.orders through a
    create, update, or read event, read from the beginning of the topic up to its
    current end offset."""
    from kafka import TopicPartition

    client = core.consumer()
    try:
        ids = client.partitions_for_topic(core.DATA_TOPIC)
        if not ids:
            raise RuntimeError("Kafka topic unavailable: " + core.DATA_TOPIC)
        partitions = [TopicPartition(core.DATA_TOPIC, i) for i in sorted(ids)]
        client.assign(partitions)
        end = core.kafka_fence(client, partitions)
        for partition in partitions:
            client.seek(partition, 0)
        delivered = set()
        remaining = dict(end)
        while any(client.position(p) < offset for p, offset in remaining.items()):
            polled = client.poll(timeout_ms=1000)
            if not polled:
                if all(client.position(p) >= offset for p, offset in remaining.items()):
                    break
                continue
            for batch in polled.values():
                for message in batch:
                    envelope = message.value or {}
                    if envelope.get("op") in ("c", "u", "r"):
                        order_id = (envelope.get("after") or {}).get("id")
                        if order_id is not None:
                            delivered.add(order_id)
        return delivered
    finally:
        client.close(autocommit=False, timeout_ms=500)


def hold(mode, latch_name):
    """A hold's verdict: clean unless the monitor has latched a violation of
    this kind, and only while the monitor is still reporting. An observer
    that has gone silent for longer than its own error grace period cannot
    produce a positive preservation verdict."""
    clean = not (STATE / latch_name).exists() and core.observed_recently()
    report = {
        "mode": mode,
        "passed": clean,
        "violation": _read_json(STATE / latch_name),
        "observed_recently": core.observed_recently(),
    }
    return clean, report


def _format_offsets(offsets):
    """Partition offsets as `partition:offset` pairs, sorted by partition, so
    a fenced-vs-consumed comparison in the one-line detail below reads the
    same way run to run."""
    return ",".join(f"{k}:{v}" for k, v in sorted(offsets.items(), key=lambda kv: str(kv[0])))


def _prior_sample_count(path):
    """How many polls of this converge entry have already been recorded,
    before the one this call is about to add -- read before record_sample()
    appends the current call's own line."""
    if not path.exists():
        return 0
    return len([line for line in path.read_text().splitlines() if line.strip()])


def orders(deadline):
    """The converge objective: a fresh marker order is delivered on
    cdc.public.orders carrying this connector's own provenance, and at least
    DELIVERY_THRESHOLD of the order ids the current month's partition already
    held at baseline have been delivered by now (challenge.py's monitor()
    accumulates every id it ever sees into seen-ids.json continuously)."""
    started_at = time.monotonic()
    seeded = set(_read_json(SEEDED_IDS, []))
    if not seeded:
        return False, {
            "mode": "orders",
            "passed": False,
            "reason": "no seeded-current-month-ids baseline was recorded",
            "detail": "reason=no_seeded_baseline",
        }

    budget = min(DELIVERY_BUDGET_SEC, deadline - time.monotonic())
    result = core.marker_challenge(budget=budget)
    marker_ok = bool(result["delivered"])
    provenance_problems = []
    matched = result.get("matched") or {}
    source = matched.get("source") or {}
    if marker_ok:
        if source.get("table") != result.get("partition_table"):
            provenance_problems.append(
                "the marker event named a different table than the current "
                "month partition it was written into"
            )
        if "postgresql" not in str(source.get("connector") or "").lower():
            provenance_problems.append("the marker event does not name the Postgres connector")
        if source.get("txId") in (None, ""):
            provenance_problems.append("the marker event carries no source transaction")

    seen = set(_read_json(SEEN_IDS, []))
    delivered_seeded = seeded & seen
    missing_pre_repair = len(seeded - seen)
    backfilled = missing_pre_repair == 0
    ratio = core.backfill_ratio(seeded, seen)

    topic_baseline = _read_json(STATE / "topic-baseline.json", {}) or {}
    fenced_end_offsets = (topic_baseline.get(core.DATA_TOPIC) or {}).get("end") or {}
    consumed_to_offsets = _read_json(STATE / "orders-tail-offsets.json", {}) or {}
    sample_number = _prior_sample_count(STATE / "orders-samples.jsonl") + 1

    concurrent_missing = _read_json(STATE / "concurrent-updates-missing.json", 0)
    passed = marker_ok and not provenance_problems and backfilled and (concurrent_missing == 0)
    if marker_ok and not provenance_problems:
        (STATE / "marker-delivered.json").write_text(json.dumps(True))
    elapsed_sec = time.monotonic() - started_at
    detail = " ".join(
        [
            f"delivery_ratio={ratio:.4f}",
            f"missing_pre_repair_month_orders={missing_pre_repair}",
            f"delivered_seeded_ids={len(delivered_seeded)}",
            f"seeded_current_month_ids={len(seeded)}",
            f"seen_ids_total={len(seen)}",
            f"marker_delivered={marker_ok}",
            f"provenance_problems={len(provenance_problems)}",
            f"concurrent_updates_missing={concurrent_missing}",
            f"fenced_end_offsets={_format_offsets(fenced_end_offsets)}",
            f"consumed_to_offsets={_format_offsets(consumed_to_offsets)}",
            f"sample_number={sample_number}",
            f"elapsed_sec={elapsed_sec:.2f}",
        ]
    )
    return passed, {
        "mode": "orders",
        "passed": passed,
        "marker": result,
        "marker_delivered": marker_ok,
        "provenance_problems": provenance_problems,
        "seeded_current_month_ids": len(seeded),
        "delivered_seeded_ids": len(delivered_seeded),
        "missing_pre_repair_month_orders": missing_pre_repair,
        "seen_ids_total": len(seen),
        "delivery_ratio": ratio,
        "delivery_threshold": 1.0,
        "backfilled": backfilled,
        "concurrent_updates_missing": concurrent_missing,
        "fenced_end_offsets": fenced_end_offsets,
        "consumed_to_offsets": consumed_to_offsets,
        "sample_number": sample_number,
        "elapsed_sec": elapsed_sec,
        "detail": detail,
    }


def get_status() -> dict:
    """Computes all distinct raw numerical and boolean fields for the status exporter."""
    ready = BASELINE_QUIESCENCE.exists() and core.observed_recently()

    slot_clean = not (STATE / "slot-violation.json").exists()
    route_clean = not (STATE / "route-violation.json").exists()
    recent = BASELINE_QUIESCENCE.exists()
    slot_and_offsets_preserved = slot_clean and route_clean and recent
    slot_dropped_or_rewound = not slot_and_offsets_preserved

    pg_missing = int(_read_json(STATE / "pg-missing.json", 0) or 0)
    prior_month_missing_or_corrupted = pg_missing + (0 if (slot_clean and route_clean) else 1)
    prior_month_rows_intact = (
        (prior_month_missing_or_corrupted == 0) and slot_clean and route_clean and recent
    )

    seeded = set(_read_json(SEEDED_IDS, []))
    pre_repair_month_orders_count = len(seeded)
    seen = set(_read_json(SEEN_IDS, []))
    delivered_pre_repair = (seeded & seen) if (slot_clean and route_clean) else set()
    delivered_pre_repair_count = len(delivered_pre_repair)
    missing_pre_repair_month_orders = len(seeded - delivered_pre_repair) if seeded else 0

    concurrent_updates_missing = _read_json(STATE / "concurrent-updates-missing.json", 0)
    marker_delivered = (
        bool(_read_json(STATE / "marker-delivered.json", False)) and slot_clean and route_clean
    )
    fresh_post_repair_writes_delivered = marker_delivered and (concurrent_updates_missing == 0)
    post_repair_streamed_orders_ok = fresh_post_repair_writes_delivered

    slot_passed = 1 if slot_and_offsets_preserved else 0
    history_passed = 1 if prior_month_rows_intact else 0
    route_passed = 1 if slot_and_offsets_preserved else 0
    orders_passed = (
        1 if (missing_pre_repair_month_orders == 0 and fresh_post_repair_writes_delivered) else 0
    )

    return {
        "ready": ready,
        "slot_and_offsets_preserved": slot_and_offsets_preserved,
        "slot_dropped_or_rewound": slot_dropped_or_rewound,
        "prior_month_rows_intact": prior_month_rows_intact,
        "prior_month_missing_or_corrupted": prior_month_missing_or_corrupted,
        "pre_repair_month_orders_count": pre_repair_month_orders_count,
        "delivered_pre_repair_month_orders": delivered_pre_repair_count,
        "missing_pre_repair_month_orders": missing_pre_repair_month_orders,
        "fresh_post_repair_writes_delivered": fresh_post_repair_writes_delivered,
        "post_repair_streamed_orders_ok": post_repair_streamed_orders_ok,
        "concurrent_updates_missing": concurrent_updates_missing,
        "slot": slot_passed,
        "history": history_passed,
        "route": route_passed,
        "orders": orders_passed,
    }


def record_sample(name, report):
    path = STATE / name
    try:
        STATE.mkdir(exist_ok=True)
        lines = path.read_text().splitlines() if path.exists() else []
        lines.append(json.dumps(report, sort_keys=True, default=str))
        path.write_text("\n".join(lines[-200:]) + "\n")
    except Exception as exc:
        print(
            f"the sample report could not be appended to {name} ({type(exc).__name__})",
            file=sys.stderr,
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode", choices=["orders", "slot", "route", "history", "baseline", "status"]
    )
    args = parser.parse_args()
    if args.mode == "orders":
        budget = ORDERS_BUDGET_SEC
    elif args.mode == "baseline":
        budget = BASELINE_BUDGET_SEC
    else:
        budget = GATE_BUDGET_SEC

    def timed_out(*_):
        raise TimeoutError(f"verify exceeded its {budget:.0f}-second hard budget")

    signal.signal(signal.SIGALRM, timed_out)
    signal.alarm(int(budget))
    started = time.monotonic()
    try:
        if args.mode == "status":
            print(json.dumps(get_status(), sort_keys=True, indent=2))
            return
        if args.mode == "baseline":
            print(json.dumps(record_baseline(), sort_keys=True, default=str), file=sys.stderr)
            return
        if args.mode == "orders":
            passed, report = orders(started + budget - 5.0)
            log = "orders-samples.jsonl"
        elif args.mode == "slot":
            passed, report = hold("slot", "slot-violation.json")
            log = "hold-slot-samples.jsonl"
        elif args.mode == "route":
            passed, report = hold("route", "route-violation.json")
            log = "hold-route-samples.jsonl"
        else:
            passed, report = hold("history", "history-violation.json")
            log = "hold-history-samples.jsonl"
        print(json.dumps(report, sort_keys=True, default=str), file=sys.stderr)
        record_sample(log, report)
        if args.mode == "orders" and not passed:
            print("0 " + report.get("detail", ""))
        else:
            print("1" if passed else "0")
    except Exception as exc:
        print(type(exc).__name__ + ": " + str(exc), file=sys.stderr)
        raise
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    main()
