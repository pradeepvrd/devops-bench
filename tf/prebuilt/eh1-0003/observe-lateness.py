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

import json
import os
import time
from datetime import datetime

from kafka import KafkaConsumer, TopicPartition

consumer = KafkaConsumer(
    bootstrap_servers=os.environ["KAFKA_BOOTSTRAP"],
    group_id=None,
    enable_auto_commit=False,
    request_timeout_ms=8000,
    api_version_auto_timeout_ms=5000,
)
try:
    parts = [
        TopicPartition(os.environ["TOPIC"], p)
        for p in sorted(consumer.partitions_for_topic(os.environ["TOPIC"]) or [])
    ]
    if not parts:
        raise RuntimeError("raw topic has no partitions")
    consumer.assign(parts)
    # Fence history by Kafka offset, never by event_time: injected late events
    # appended during this observation must still be counted and rejected.
    starts = consumer.end_offsets(parts)
    for part in parts:
        consumer.seek(part, starts[part])
    valid = late = malformed = 0
    latest = 0
    ends = None
    observe_until = time.monotonic() + 8
    drain_until = observe_until + 8
    while time.monotonic() < drain_until:
        if ends is None and time.monotonic() >= observe_until:
            # Freeze the complete observation, then allow bounded drain time.
            ends = consumer.end_offsets(parts)
        if ends is not None and all(consumer.position(p) >= ends[p] for p in parts):
            break
        for part, records in consumer.poll(timeout_ms=500).items():
            for record in records:
                if record.offset < starts[part] or (
                    ends is not None and record.offset >= ends[part]
                ):
                    continue
                try:
                    event = json.loads(record.value)
                    event_ms = (
                        datetime.fromisoformat(
                            event["event_time"].replace("Z", "+00:00")
                        ).timestamp()
                        * 1000
                    )
                except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
                    malformed += 1
                    continue
                valid += 1
                latest = max(latest, record.timestamp)
                late += not (-1000 <= record.timestamp - event_ms <= 10000)
    complete = ends is not None and all(consumer.position(p) >= ends[p] for p in parts)
    age_ms = time.time() * 1000 - latest if valid else None
    reasons = []
    if not complete:
        reasons.append("incomplete_observation")
    if valid < 30:
        reasons.append("fewer_than_30_valid_fresh_records")
    if late:
        reasons.append("late_or_future_event_time")
    if age_ms is None or age_ms > 90000:
        reasons.append("stale_or_missing_input")
    report = {
        "reasons": reasons,
        "valid": valid,
        "late": late,
        "malformed": malformed,
        "latest_age_ms": age_ms,
        "complete": complete,
        "offsets": [
            {
                "partition": getattr(p, "partition", p),
                "start": starts[p],
                "end": ends[p] if ends is not None else None,
                "position": consumer.position(p),
            }
            for p in parts
        ],
    }
    # The checker compares stdout to exactly "pass". Failure details belong in
    # stdout so the verifier's saved reason retains them (stderr may be lost).
    print("fail " + json.dumps(report, sort_keys=True) if reasons else "pass")
finally:
    consumer.close()
