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

import contextlib
import json
import logging
import math
import os
import random
import threading
import time
import uuid
from collections import deque
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from kafka import KafkaConsumer, KafkaProducer, TopicPartition
from kafka.errors import KafkaError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("traffic-engine")

SEED = int(os.environ.get("SEED", "42"))
BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "streaming-kafka-kafka-bootstrap:9092")
TOPIC = os.environ.get("TOPIC", "events.raw")
PROFILE_PATH = os.environ.get("PROFILE_PATH", "/profile/profile.json")
STATUS_PORT = int(os.environ.get("STATUS_PORT", "8080"))

CATEGORIES = [
    "electronics",
    "apparel",
    "home",
    "beauty",
    "sports",
    "toys",
    "grocery",
    "books",
]
CURRENCIES = ["USD", "EUR", "GBP"]

_OBSERVED_LOCK = threading.Lock()
_OBSERVED_TOPICS = {}
_PRODUCER_METRICS = {
    "sent_count": 0,
    "failed_count": 0,
    "malformed_count": 0,
    "duplicate_count": 0,
}


def load_profile(path):
    with open(path) as f:
        return json.load(f)


def build_zipf_table(pool_size, alpha):
    denom = sum(1.0 / (r**alpha) for r in range(1, pool_size + 1))
    weights = [(1.0 / (r**alpha)) / denom for r in range(1, pool_size + 1)]
    cumulative = []
    total = 0.0
    for w in weights:
        total += w
        cumulative.append(total)
    return cumulative


def pick_zipf(rng, cumulative_table):
    target = rng.random()
    lo, hi = 0, len(cumulative_table) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if cumulative_table[mid] < target:
            lo = mid + 1
        else:
            hi = mid
    return lo


def pick_weighted(rng, mix):
    keys = list(mix.keys())
    weights = list(mix.values())
    total = sum(weights)
    target = rng.random() * total
    cumulative = 0.0
    for k, w in zip(keys, weights, strict=False):
        cumulative += w
        if target <= cumulative:
            return k
    return keys[-1]


def diurnal_multiplier(rng, elapsed_seconds, day_length_minutes, amplitude):
    if day_length_minutes <= 0:
        return 1.0
    day_length_seconds = day_length_minutes * 60.0
    phase = (elapsed_seconds % day_length_seconds) / day_length_seconds
    wave = math.sin(2 * math.pi * phase - math.pi / 2)
    return max(0.05, 1.0 + amplitude * wave)


def make_event(rng, profile, user_ids, product_ids, run_id, seq):
    user_id = user_ids[pick_zipf(rng, profile["_user_cumulative"])]
    product_id = product_ids[pick_zipf(rng, profile["_product_cumulative"])]
    event_type = pick_weighted(rng, profile["event_mix"])
    category = rng.choice(CATEGORIES)
    quantity = rng.randint(1, 5)
    unit_price = round(rng.uniform(2.5, 499.99), 2)
    currency = rng.choice(CURRENCIES)

    now = datetime.now(UTC)
    event_time = now
    if rng.random() < profile.get("late_fraction", 0.0):
        delay = rng.uniform(1, profile.get("late_max_seconds", 1))
        event_time = now - timedelta(seconds=delay)

    event = {
        "event_id": str(uuid.UUID(int=rng.getrandbits(128))),
        "run_id": run_id,
        "seq": seq,
        "event_type": event_type,
        "event_time": event_time.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "user_id": user_id,
        "session_id": f"sess-{user_id}-{seq % 97}",
        "product_id": product_id,
        "category": category,
        "quantity": quantity,
        "unit_price": unit_price,
        "currency": currency,
    }

    if rng.random() < profile.get("malformed_fraction", 0.0):
        event = malform(rng, event)

    return user_id, event


def malform(rng, event):
    choice = rng.random()
    if choice < 0.5:
        raw = json.dumps(event)
        cut = rng.randint(len(raw) // 3, len(raw) - 1)
        return raw[:cut]
    else:
        event = dict(event)
        event["unit_price"] = "N/A"
        return event


def to_bytes(event):
    if isinstance(event, str):
        return event.encode("utf-8")
    return json.dumps(event).encode("utf-8")


def kafka_auth_kwargs(profile):
    kwargs = {}
    sec_proto = os.environ.get("KAFKA_SECURITY_PROTOCOL") or profile.get("security_protocol")
    if sec_proto:
        kwargs["security_protocol"] = sec_proto
    sasl_mech = os.environ.get("KAFKA_SASL_MECHANISM") or profile.get("sasl_mechanism")
    if sasl_mech:
        kwargs["sasl_mechanism"] = sasl_mech
    sasl_user = os.environ.get("KAFKA_USER") or profile.get("sasl_username")
    if sasl_user:
        kwargs["sasl_plain_username"] = sasl_user
    sasl_pass = os.environ.get("KAFKA_PASSWORD") or profile.get("sasl_password")
    if sasl_pass:
        kwargs["sasl_plain_password"] = sasl_pass
    return kwargs


def connect(bootstrap, profile):
    auth = kafka_auth_kwargs(profile)
    while True:
        try:
            producer = KafkaProducer(
                bootstrap_servers=bootstrap,
                key_serializer=lambda k: k.encode("utf-8") if k else None,
                value_serializer=lambda v: v,
                retries=5,
                linger_ms=50,
                acks="all",
                **auth,
            )
            log.info("connected to kafka at %s", bootstrap)
            return producer
        except KafkaError as exc:
            log.warning("kafka connect failed: %s, retrying in 5s", exc)
            time.sleep(5)


def _get_or_init_topic_entry(topic_name):
    if topic_name not in _OBSERVED_TOPICS:
        _OBSERVED_TOPICS[topic_name] = {
            "message_count": 0,
            "recent_events": deque(maxlen=500),
            "latest_timestamp_ms": None,
            "latest_offset": None,
            "latest_payload": None,
            "window_rollups": {},
            "cdc_tables": {},
        }
    return _OBSERVED_TOPICS[topic_name]


def _process_observed_record(record):
    now_ms = time.time() * 1000.0
    t_name = record.topic
    rec_ts = record.timestamp or now_ms
    payload_obj = None
    is_valid = False
    is_late = False

    try:
        raw_str = (
            record.value.decode("utf-8") if isinstance(record.value, bytes) else str(record.value)
        )
        payload_obj = json.loads(raw_str)
        if isinstance(payload_obj, dict):
            is_valid = True
            if "event_time" in payload_obj and isinstance(payload_obj["event_time"], str):
                try:
                    ev_ms = (
                        datetime.fromisoformat(
                            payload_obj["event_time"].replace("Z", "+00:00")
                        ).timestamp()
                        * 1000.0
                    )
                    if not (-1000.0 <= (rec_ts - ev_ms) <= 10000.0):
                        is_late = True
                except Exception:
                    pass
    except Exception:
        is_valid = False

    with _OBSERVED_LOCK:
        entry = _get_or_init_topic_entry(t_name)
        entry["message_count"] += 1
        entry["latest_timestamp_ms"] = max(entry["latest_timestamp_ms"] or 0, rec_ts)
        entry["latest_offset"] = max(entry["latest_offset"] or 0, record.offset)
        entry["recent_events"].append((now_ms, is_valid, is_late))
        if isinstance(payload_obj, dict):
            entry["latest_payload"] = payload_obj
            if "window_start" in payload_obj and "category" in payload_obj:
                w_start = str(payload_obj["window_start"])
                cat = str(payload_obj["category"])
                entry["window_rollups"].setdefault(w_start, {})[cat] = {
                    "order_count": payload_obj.get("order_count"),
                    "revenue": float(payload_obj["revenue"])
                    if payload_obj.get("revenue") is not None
                    else None,
                }
            envelope = payload_obj.get("envelope") if "envelope" in payload_obj else payload_obj
            if isinstance(envelope, dict) and "source" in envelope and "after" in envelope:
                source = envelope.get("source") or {}
                after = envelope.get("after") or {}
                tbl = source.get("table")
                op = envelope.get("op")
                snap = source.get("snapshot")
                if tbl and op in ("c", "u") and snap not in (True, "true"):
                    t_info = entry["cdc_tables"].setdefault(
                        str(tbl), {"count": 0, "latest_op": None, "latest_after": None}
                    )
                    t_info["count"] += 1
                    t_info["latest_op"] = op
                    t_info["latest_after"] = after


def topic_observer_loop(bootstrap, profile):
    auth = kafka_auth_kwargs(profile)
    assigned = set()
    client = None
    last_discover = 0.0
    while True:
        try:
            if client is None:
                client = KafkaConsumer(
                    bootstrap_servers=bootstrap,
                    group_id=None,
                    enable_auto_commit=False,
                    request_timeout_ms=6000,
                    api_version_auto_timeout_ms=5000,
                    consumer_timeout_ms=500,
                    **auth,
                )
            now = time.monotonic()
            if now - last_discover >= 5.0:
                last_discover = now
                wanted_topics = set(profile.get("observe_topics", []))
                wanted_topics.add(TOPIC)
                if profile.get("observe_all_topics", True):
                    try:
                        all_t = client.topics() or set()
                        for t in all_t:
                            if not t.startswith("__"):
                                wanted_topics.add(t)
                    except Exception:
                        pass
                new_tps = set()
                for t in wanted_topics:
                    try:
                        parts = client.partitions_for_topic(t)
                        if parts:
                            for p in parts:
                                new_tps.add(TopicPartition(t, p))
                    except Exception:
                        pass
                if new_tps != assigned and new_tps:
                    added = new_tps - assigned
                    assigned = new_tps
                    client.assign(list(assigned))
                    for tp in added:
                        if tp.topic == "settlement.rollup" or tp.topic.startswith("cdc."):
                            client.seek_to_beginning(tp)
                        else:
                            end_off = client.end_offsets([tp]).get(tp, 0)
                            client.seek(tp, max(0, end_off - 50))
            if assigned:
                batch_map = client.poll(timeout_ms=400)
                for records in batch_map.values():
                    for rec in records:
                        _process_observed_record(rec)
            else:
                time.sleep(1.0)
        except Exception as exc:
            log.debug("topic observer error: %s", exc)
            if client is not None:
                with contextlib.suppress(Exception):
                    client.close()
                client = None
            time.sleep(2.0)


def build_status_snapshot(profile):
    now_ms = time.time() * 1000.0
    cutoff_60s = now_ms - 60000.0
    topics_snap = {}
    with _OBSERVED_LOCK:
        for t_name, info in _OBSERVED_TOPICS.items():
            recent_valid = sum(
                1 for ts, val, _ in info["recent_events"] if ts >= cutoff_60s and val
            )
            recent_late = sum(
                1 for ts, val, late in info["recent_events"] if ts >= cutoff_60s and val and late
            )
            latest_ts = info["latest_timestamp_ms"]
            age_ms = int(now_ms - latest_ts) if latest_ts is not None else None
            topics_snap[t_name] = {
                "message_count": info["message_count"],
                "recent_valid_60s": recent_valid,
                "recent_late_60s": recent_late,
                "latest_timestamp_ms": latest_ts,
                "latest_age_ms": age_ms,
                "latest_offset": info["latest_offset"],
                "latest_payload": info["latest_payload"],
                "window_rollups": info["window_rollups"],
                "cdc_tables": info["cdc_tables"],
            }
    clean_profile = {k: v for k, v in profile.items() if not k.startswith("_")}
    return {
        "status": "ok",
        "producer": dict(_PRODUCER_METRICS),
        "profile": clean_profile,
        "topics": topics_snap,
    }


def start_status_server(profile):
    class StatusHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/status", "/status/"):
                self.send_response(404)
                self.end_headers()
                return
            payload = build_status_snapshot(profile)
            body = json.dumps(payload, sort_keys=True).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            pass

    server = ThreadingHTTPServer(("0.0.0.0", STATUS_PORT), StatusHandler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    log.info("started traffic-engine status server on 0.0.0.0:%d/status", STATUS_PORT)
    return server


def main():
    profile = load_profile(PROFILE_PATH)
    rng = random.Random(SEED)
    run_id = f"run-{uuid.uuid4().hex[:12]}"

    start_status_server(profile)
    obs_thread = threading.Thread(
        target=topic_observer_loop, args=(BOOTSTRAP, profile), daemon=True
    )
    obs_thread.start()

    if not profile.get("producer_enabled", True) or profile.get("base_rate_eps", 10.0) <= 0:
        log.info("producer disabled by profile; running in observer-only mode")
        while True:
            time.sleep(60)

    user_pool_size = profile.get("user_pool_size", 5000)
    user_ids = [f"u-{SEED}-{i}" for i in range(user_pool_size)]
    product_ids = [str(i) for i in range(1, 51)]
    profile["_user_cumulative"] = build_zipf_table(user_pool_size, profile.get("zipf_alpha", 1.1))
    profile["_product_cumulative"] = build_zipf_table(
        len(product_ids), profile.get("zipf_alpha", 1.1)
    )

    producer = connect(BOOTSTRAP, profile)

    last_failure_log = 0.0
    seq = 0
    burst_until = 0.0
    start = time.monotonic()
    last_heartbeat = start

    def on_send_error(exc):
        nonlocal last_failure_log
        _PRODUCER_METRICS["failed_count"] += 1
        now = time.monotonic()
        if now - last_failure_log >= 10:
            log.warning("send failed: %s", exc)
            last_failure_log = now

    log.info(
        "starting traffic-engine seed=%s topic=%s profile=%s run_id=%s",
        SEED,
        TOPIC,
        PROFILE_PATH,
        run_id,
    )

    while True:
        loop_start = time.monotonic()
        elapsed = loop_start - start

        burst_cfg = profile.get(
            "burst", {"prob_per_minute": 0.0, "duration_seconds": 0, "multiplier": 1.0}
        )
        if (
            loop_start >= burst_until
            and rng.random() < burst_cfg.get("prob_per_minute", 0.0) / 60.0
        ):
            burst_until = loop_start + burst_cfg.get("duration_seconds", 0)

        burst_active = loop_start < burst_until
        multiplier = diurnal_multiplier(
            rng,
            elapsed,
            profile.get("day_length_minutes", 1440),
            profile.get("diurnal_amplitude", 0.0),
        )
        if burst_active:
            multiplier *= burst_cfg.get("multiplier", 1.0)

        target_eps = max(0.1, profile.get("base_rate_eps", 10.0) * multiplier)
        sleep_interval = 1.0 / target_eps

        seq += 1
        user_id, event = make_event(rng, profile, user_ids, product_ids, run_id, seq)
        if (
            isinstance(event, dict)
            and "unit_price" in event
            and event["unit_price"] == "N/A"
            or isinstance(event, str)
        ):
            _PRODUCER_METRICS["malformed_count"] += 1

        payload = to_bytes(event)
        try:
            producer.send(TOPIC, key=user_id, value=payload).add_errback(on_send_error)
            _PRODUCER_METRICS["sent_count"] += 1
            if rng.random() < profile.get("duplicate_fraction", 0.0):
                producer.send(TOPIC, key=user_id, value=payload).add_errback(on_send_error)
                _PRODUCER_METRICS["sent_count"] += 1
                _PRODUCER_METRICS["duplicate_count"] += 1
        except KafkaError as exc:
            log.warning("send failed: %s", exc)
        except Exception as exc:
            log.warning("unexpected send error: %s", exc)

        now = time.monotonic()
        if now - last_heartbeat >= 30:
            day_length_seconds = max(1.0, profile.get("day_length_minutes", 1440) * 60.0)
            phase = (elapsed % day_length_seconds) / day_length_seconds
            log.info(
                "heartbeat target_eps=%.2f sent=%d failed=%d malformed=%d duplicates=%d "
                "phase_of_day=%.2f burst_active=%s",
                target_eps,
                _PRODUCER_METRICS["sent_count"],
                _PRODUCER_METRICS["failed_count"],
                _PRODUCER_METRICS["malformed_count"],
                _PRODUCER_METRICS["duplicate_count"],
                phase,
                burst_active,
            )
            last_heartbeat = now

        elapsed_loop = time.monotonic() - loop_start
        remaining = sleep_interval - elapsed_loop
        if remaining > 0:
            time.sleep(remaining)


if __name__ == "__main__":
    while True:
        try:
            main()
        except Exception as exc:
            log.exception("fatal error in main loop, restarting in 5s: %s", exc)
            time.sleep(5)
