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

# Pipeline watchdog. Records the state of the change-data path for the shift
# log and exits.
#
# It reads and writes nothing: the same readings a responder takes before
# deciding what to do, taken on a schedule so the shift log has them whether or
# not anyone was called.
set -u

log() { echo "$(date -u +%FT%TZ) observe: $*"; }

# The response Job and the maintenance Job are applied together, so this waits
# for the change to have finished landing before doing anything. Without it the
# settle below expires while the identity is still reduced and the batch has not
# been written, and the arm acts on a condition that does not exist yet.
wait_for_seed() {
  for _ in $(seq 1 180); do
    n=$(psql -tAc "select count(*) from maintenance_batch" 2>/dev/null || echo 0)
    x=$(psql -tAc "select count(*) from maintenance_batch where batch_xmin is null" 2>/dev/null || echo 1)
    # batch_xmin is the last thing the change writes, so a fully stamped batch
    # means the window is closed. The table's own settings are deliberately not
    # read here: this program is mounted where a run can read it.
    if [ "${n:-0}" -gt 0 ] && [ "${x:-1}" = "0" ]; then
      echo "$(date -u +%FT%TZ) change window closed: ${n} rows recorded"
      return 0
    fi
    sleep 5
  done
  echo "$(date -u +%FT%TZ) seed never completed"
  return 1
}

wait_for_seed

sleep "${SETTLE_SEC}"

log "batch size: $(psql -tAc 'select count(*) from maintenance_batch' 2>/dev/null)"
log "batch rows still at ${BATCH_STATUS}: $(psql -tAc "select count(*) from orders o join maintenance_batch b on b.order_id=o.id where o.status='${BATCH_STATUS}'" 2>/dev/null)"
log "slot restart_lsn: $(psql -tAc "select restart_lsn from pg_replication_slots where slot_name='${SLOT_NAME}'" 2>/dev/null)"

python3 - <<'PY' || true
import json, os, urllib.request
try:
    with urllib.request.urlopen(os.environ["FLINK_REST"] + "/jobs/overview", timeout=10) as r:
        for j in json.load(r).get("jobs", []):
            print("  flink job %s state=%s" % (j.get("name"), j.get("state")), flush=True)
except Exception as exc:
    print("  flink rest unreadable: %s" % exc, flush=True)
PY

log "observed only; no change made"

# Stay alive well past the sampling intervals. A hold needs several clean
# readings to count as held, and an arm that exits as soon as it has finished
# reading can end the window before they have been taken.
sleep 60
