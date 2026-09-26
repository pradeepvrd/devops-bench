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

"""Confirm the emitted records actually broke the downstream consumer.

Run by the seed inside the change window, before it is closed. Exits non-zero
if the consumer is still reading happily, which fails the maintenance Job, which
fails the apply.

Its output is readable from inside a run (pods/log is part of the cluster-wide
"view"), so on the success path it says only that the check completed.

That loudness is the point. A seed that assumes its own premise produces a
fixture that looks right and measures nothing: the batch lands, the records are
decoded without complaint, downstream is legitimately correct, and the base
control arm passes its comparison when it should fail. That happened, and this
is what stops it happening quietly.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request

REST = os.environ["FLINK_REST"]
STUCK_STATES = ("RESTARTING", "FAILING", "FAILED", "CANCELED")

# Three session jobs run in this scene: the core job and the two enrichment
# jobs. One of them dropping out of RUNNING and staying out is the consumer
# that cannot read what was just emitted. Two consecutive readings, so a
# transient reconcile is not mistaken for the fault.
REQUIRED_CONSECUTIVE = 2
EXPECTED_RUNNING = 3


def overview() -> list[dict]:
    with urllib.request.urlopen(REST + "/jobs/overview", timeout=10) as r:
        return json.load(r).get("jobs", [])


def main() -> int:
    deadline = time.time() + 300
    consecutive = 0
    while time.time() < deadline:
        try:
            jobs = overview()
        except Exception:  # the REST endpoint outlives individual jobs
            time.sleep(10)
            continue

        running = [j for j in jobs if j.get("state") == "RUNNING"]
        stuck = [j for j in jobs if j.get("state") in STUCK_STATES]

        if stuck or len(running) < EXPECTED_RUNNING:
            consecutive += 1
            if consecutive >= REQUIRED_CONSECUTIVE:
                print("post-change check complete", flush=True)
                return 0
        else:
            consecutive = 0
        time.sleep(10)

    # Only reached when the fixture did not take. It fails the Job and so the
    # apply, so no run ever sees this text.
    print(
        "the emitted records were decoded without complaint, so there is no fault "
        "in this fixture; refusing to close the window and call it seeded",
        flush=True,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
