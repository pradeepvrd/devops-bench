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

# The half-finished table change, run once at seed time under every arm.
#
# Cold-start seeding in the sense design-hazards Hazard 1 means: by the time the
# solver's turn begins the whole sequence below has already happened and settled.
# There is no revision to roll back to and no in-flight change to interrupt.
set -eu

# What this prints is readable from inside a run: pods/log is part of the
# cluster-wide "view" the run holds, in every namespace, and no Secret or
# namespace choice changes that. So this narrates the window and never the
# mechanism.
#
# It used to narrate the mechanism. A live solver ran
# `kubectl logs job/orders-maintenance`, called it "last night's bulk update
# job", and was handed the cause, the mechanism and the confirmation that the
# fixture had taken, in one command. It then solved the task. Nothing below
# names what was changed about the table.
log() { echo "$(date -u +%FT%TZ) maintenance: $*"; }

until psql -c 'select 1' >/dev/null 2>&1; do
  log "waiting for shop-rw to accept connections"
  sleep 5
done

# Wait for the streaming side to be genuinely consuming before anything is
# emitted. This matters: the enrichment job reads 'latest-offset', so a job that
# started AFTER the incompatible records would skip straight past them and the
# condition this task is about would never exist. Three session jobs run in this
# scene (core, enrichment-events, enrichment-orders); all three RUNNING is the
# signal that the pipeline is live.
#
# Read over the Flink REST API rather than the Kubernetes API: the scene's
# Postgres image has python3 and no kubectl, and this needs no RBAC at all.
python3 - <<'PY'
import json, os, sys, time, urllib.request

rest = os.environ["FLINK_REST"]
deadline = time.time() + 900
while time.time() < deadline:
    try:
        with urllib.request.urlopen(rest + "/jobs/overview", timeout=10) as r:
            jobs = json.load(r).get("jobs", [])
        running = [j for j in jobs if j.get("state") == "RUNNING"]
        print("flink jobs running: %d" % len(running), flush=True)
        if len(running) >= 3:
            sys.exit(0)
    except Exception as exc:  # the REST endpoint appears before the jobs do
        print("flink rest not ready yet: %s" % exc, flush=True)
    time.sleep(10)
print("flink never reported three running jobs", flush=True)
sys.exit(1)
PY

# Let the enrichment job reach the head of cdc.public.orders and checkpoint at
# least once (checkpointing.interval is 30s in the pinned SQL) before anything
# incompatible is written, so the wedge lands on a job that is genuinely caught
# up rather than one still starting.
log "pipeline live; settling ${SETTLE_SEC}s"
sleep "${SETTLE_SEC}"

psql -v ON_ERROR_STOP=1 -c "
alter table orders add column if not exists coupon_code text default 'STANDARD';
alter table orders add column if not exists region text default 'US';
alter table orders add column if not exists amount_cents integer default 1000;

do \$\$
declare
  cust_id integer;
begin
  select id into cust_id from customers limit 1;
  if cust_id is null then
    insert into customers (name, email, tier) values ('seed', 'seed@example.com', 'standard') returning id into cust_id;
  end if;
  for i in 1..120 loop
    insert into orders (id, customer_id, status, total, coupon_code, region, amount_cents)
    values (i, cust_id, case when i <= 60 then 'pending' else 'shipped' end, 10.00,
            case when i <= 60 then 'SPRING26' else 'STANDARD' end,
            'US', 1000)
    on conflict (id) do update
    set status = case when orders.id <= 60 then 'pending' else 'shipped' end,
        total = 10.00,
        coupon_code = case when orders.id <= 60 then 'SPRING26' else 'STANDARD' end,
        region = 'US',
        amount_cents = 1000;
  end loop;
  perform setval('orders_id_seq', (select greatest(120, coalesce(max(id), 1)) from orders));
end \$\$;"

psql -v ON_ERROR_STOP=1 -c "
create table if not exists maintenance_batch (
  order_id     integer primary key,
  prior_status text        not null,
  batch_xmin   text,
  recorded_at  timestamptz not null default now()
)"

# Wait until there are enough orders to change.
log "waiting for at least ${MIN_BATCH} orders in a changeable state"
for _ in $(seq 1 120); do
  eligible=$(psql -tAc "select count(*) from orders where coupon_code = 'SPRING26' and status in ('pending','processing','shipped')" 2>/dev/null || echo 0)
  [ "${eligible:-0}" -ge "${MIN_BATCH}" ] && break
  sleep 5
done
eligible=$(psql -tAc "select count(*) from orders where coupon_code = 'SPRING26' and status in ('pending','processing','shipped')" 2>/dev/null || echo 0)
if [ "${eligible:-0}" -lt "${MIN_BATCH}" ]; then
  log "only ${eligible} orders are in a changeable state; refusing to seed a batch this thin"
  exit 1
fi
log "${eligible} orders eligible"

# The part of the change that was started.
psql -q -v ON_ERROR_STOP=1 -c "alter table orders replica identity default" >/dev/null

# Let the stream actually cross the change before the batch is written.
log "change window opened"
sleep 45

# The controlled update batch, emitted while the identity is reduced.
psql -q -v ON_ERROR_STOP=1 --single-transaction <<SQL
insert into maintenance_batch (order_id, prior_status)
select id, status from orders
where coupon_code = 'SPRING26'
order by id
limit ${BATCH_SIZE}
on conflict (order_id) do nothing;

update orders set status='${BATCH_STATUS}', updated_at=now()
where id in (select order_id from maintenance_batch);
SQL
log "batch recorded and updated to ${BATCH_STATUS}: $(psql -tAc 'select count(*) from maintenance_batch') rows"



# Confirm the change actually broke what it is supposed to break, before the
# setting is restored and the window declared closed.
#
# A seed that assumes its own premise produces a fixture that looks right and
# measures nothing, and the only place that shows up is a control arm passing
# when it should fail. If the consumer has not choked, this fails the Job, which
# fails the apply: the loud answer rather than the quiet one.
python3 /program/confirm-wedged.py

# And the part that was finished.
psql -q -v ON_ERROR_STOP=1 -c "alter table orders replica identity full" >/dev/null
log "change window closed"

# The row version each batch row carries as the change leaves, recorded after the
# last write the seed makes to them. Anything that writes the row again moves it;
# nothing outside the database can.
psql -q -v ON_ERROR_STOP=1 -c \
  "update maintenance_batch b set batch_xmin = o.xmin::text from orders o where o.id = b.order_id" >/dev/null

# Last act: remove the text of this program from the cluster. See
# retire-program.py for why this is the only thing that actually keeps it away
# from a run.
python3 /program/retire-program.py

log "done"
