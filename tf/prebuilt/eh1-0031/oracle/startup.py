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

"""Native init-container readiness: wait for the debezium replication slot to
become active. Ordered (oracle.tf) behind connector_rollout, so the slot this
waits for is the connector's real, final one."""

import time

from challenge import slot_state

for _attempt in range(30):
    try:
        state = slot_state()
        row = state["row"]
        print(state, flush=True)
        if row and row[3] and row[4]:
            break
    except Exception as exc:
        print(type(exc).__name__, str(exc), flush=True)
    time.sleep(2)
else:
    raise SystemExit("debezium replication slot never became active")
