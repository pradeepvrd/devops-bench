#!/bin/bash
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

# Seed for eh1-0076. Runs once, before the turn, from a namespace the solver cannot read.
#
#   SHOP_URL    connection string for the shop database on Cluster/shop (superuser)
#   LEDGER_URL  connection string for the ledger database on Cluster/ledger (superuser)
#
# Real time throughout. pg_prepared_xacts.prepared is stamped by the server at PREPARE
# and cannot be backdated, so every other timestamp in the scene is derived from it
# rather than invented: the stranded batches are the most recent ones, and the nine that
# committed before them sit five minutes apart in the past.
#
# The last three catch-up batches ran concurrently on the coordinator's three workers,
# and the coordinator's container died at one instant with each of them at a different
# point of the protocol. Every branch below is in the state that instant leaves behind:
#   recon-0010  both sides voted YES and the decision was never journalled. Both branches
#               are in doubt. The coordinator is presumed-abort: roll back both.
#   recon-0011  the ledger voted NO, ABORT was journalled and the ledger rolled back. The
#               orders branch's rollback was never delivered: roll back the orders side.
#   recon-0012  both sides voted YES and COMMIT was journalled, but the crash came before
#               phase two reached either side. Both branches are in doubt: commit both.
# recon-0010 and recon-0011 post to the same clearing account. recon-0011 held its row
# first and released it when its ledger branch rolled back, which is when recon-0010's
# ledger branch could prepare -- the last thing the coordinator did.
#
# The coordinator itself (payments-recon) starts after this seed. Its recovery presumes
# recon-0010 aborted -- no decision was journalled -- and re-queues its invoices as a new
# batch, recon-0013, but it never rolls back recon-0010's in-doubt branches, so recon-0013
# queues behind their row locks on both databases. recon-0013 is not stranded; its
# coordinator is waiting on it. Nor does the recovery finish the two decided batches.
set -euo pipefail
: "${SHOP_URL:?}" "${LEDGER_URL:?}"
HISTORY_PER_CUSTOMER="${HISTORY_PER_CUSTOMER:-12}"
CHURN_ROUNDS="${CHURN_ROUNDS:-15}"
# The pod the crashed run was on: a pod of the coordinator's own ReplicaSet, which
# replaced it. Stack-supplied; the default serves a local run of this script.
OLD_POD="${OLD_POD:-payments-recon-6d8f9c7b44-x2mqp}"
# The provider settles two invoices a second (CHG-5120), so a 300-invoice batch sits between
# its orders vote and its ledger branch for this long.
SETTLE_SEC="${SETTLE_SEC:-150}"
# Where the crashed run's last log lines go, for the stack to publish as the on-call's
# crash report.
CRASH_REPORT="${CRASH_REPORT:-/work/crash-report.txt}"

shop()   { psql "$SHOP_URL"   -v ON_ERROR_STOP=1 -X -q "$@"; }
ledger() { psql "$LEDGER_URL" -v ON_ERROR_STOP=1 -X -q "$@"; }
say()    { echo "seed: $*"; }

say "waiting for two-phase commit to be enabled on both resource managers"
for url in "$SHOP_URL" "$LEDGER_URL"; do
  n=0
  for i in $(seq 1 120); do
    n=$(psql "$url" -tAX -c "SHOW max_prepared_transactions" 2>/dev/null || echo 0)
    [ "${n:-0}" -gt 0 ] && break
    sleep 5
  done
  [ "${n:-0}" -gt 0 ] || { echo "seed: max_prepared_transactions never became non-zero" >&2; exit 1; }
done

say "schema"
shop <<'SQL'
CREATE TABLE IF NOT EXISTS public.payment_reconciliations (
  id            bigserial PRIMARY KEY,
  batch_id      text          NOT NULL,
  gid           text          NOT NULL,
  order_id      integer       NOT NULL REFERENCES public.orders(id),
  amount        numeric(10,2) NOT NULL,
  reconciled_at timestamptz   NOT NULL
);
CREATE INDEX IF NOT EXISTS payment_reconciliations_batch ON public.payment_reconciliations (batch_id);
SQL
ledger <<'SQL'
CREATE SCHEMA IF NOT EXISTS recon;
CREATE TABLE IF NOT EXISTS public.ledger_entries (
  id        bigserial PRIMARY KEY,
  batch_id  text          NOT NULL,
  gid       text          NOT NULL,
  order_id  integer       NOT NULL,
  amount    numeric(10,2) NOT NULL,
  posted_at timestamptz   NOT NULL
);
CREATE TABLE IF NOT EXISTS public.xa_txn_log (
  gid        text PRIMARY KEY,
  batch_id   text        NOT NULL,
  branch     text        NOT NULL,
  state      text        NOT NULL,
  updated_at timestamptz NOT NULL
);
COMMENT ON TABLE public.xa_txn_log IS
  'State of this database''s branch of each reconciliation batch: PREPARED, COMMITTED or ROLLED BACK.';
-- batch_id and gid are empty on the coordinator's own events, such as a start.
CREATE TABLE IF NOT EXISTS recon.xa_decisions (
  at       timestamptz NOT NULL,
  batch_id text,
  gid      text,
  branch   text,
  event    text        NOT NULL
);
COMMENT ON TABLE recon.xa_decisions IS
  'payments-recon journal: its starts, each batch''s votes and decision, and phase-two acknowledgements.';
-- The clearing account each batch posts to. A batch's ledger branch updates its account's
-- row, so an in-doubt branch holds that row's lock until it is resolved.
CREATE TABLE IF NOT EXISTS public.ledger_accounts (
  account text PRIMARY KEY,
  posted  numeric(14,2) NOT NULL DEFAULT 0
);
INSERT INTO public.ledger_accounts (account) VALUES ('card'), ('wallet') ON CONFLICT DO NOTHING;
-- Every batch the coordinator has planned: its gid, its invoices (an id range), the
-- clearing account it posts to, and the batch it re-runs, if any.
CREATE TABLE IF NOT EXISTS recon.batches (
  batch_id   text PRIMARY KEY,
  gid        text    NOT NULL UNIQUE,
  lo         integer NOT NULL,
  hi         integer NOT NULL,
  account    text    NOT NULL,
  requeue_of text REFERENCES recon.batches (batch_id)
);
COMMENT ON TABLE recon.batches IS
  'Every reconciliation batch planned: its gid, its orders (lo..hi), its clearing account, and the batch it re-runs.';
-- The coordinator's work queue.
CREATE TABLE IF NOT EXISTS recon.backlog (
  batch_id text PRIMARY KEY REFERENCES recon.batches (batch_id)
);
COMMENT ON TABLE recon.backlog IS 'Batches waiting for payments-recon.';
SQL

say "order history"
shop <<SQL
INSERT INTO public.customers (name, email, tier)
SELECT 'Customer ' || g, 'customer' || g || '@orders.example',
       CASE WHEN g % 10 = 0 THEN 'gold' ELSE 'standard' END
FROM generate_series(1, 5000) g
ON CONFLICT (email) DO NOTHING;

INSERT INTO public.orders (customer_id, status, total, created_at, updated_at)
SELECT c.id,
       (ARRAY['delivered','delivered','delivered','shipped','cancelled'])[1 + floor(random() * 5)::int],
       round((5 + random() * 195)::numeric, 2),
       now() - random() * interval '90 days',
       now() - random() * interval '60 days'
FROM public.customers c, generate_series(1, ${HISTORY_PER_CUSTOMER});
SQL

say "twelve reconciliation batches: nine committed five minutes apart, the last three stranded together"
# One insert per batch, so each batch's membership is an explicit id range rather than
# something inferred later. 'invoiced' and 'reconciled' are outside the writer's state
# machine -- it selects pending/processing/shipped to update and delivered/cancelled to
# delete -- so it can never pick a row a stranded branch holds. Filtering on status as
# well as the range keeps out any order the writer inserted inside the same id span.
declare -a LO HI GID
for b in $(seq 1 12); do
  range=$(psql "$SHOP_URL" -tAX -F ' ' -v ON_ERROR_STOP=1 -c "
    WITH ins AS (
      INSERT INTO public.orders (customer_id, status, total, created_at, updated_at)
      SELECT c.id, 'invoiced', round((5 + random() * 195)::numeric, 2),
             now() - make_interval(mins => (12 - $b) * 5 + 4),
             now() - make_interval(mins => (12 - $b) * 5 + 4)
      FROM (SELECT id FROM public.customers ORDER BY random() LIMIT 300) c
      RETURNING id)
    SELECT min(id), max(id) FROM ins")
  LO[$b]=${range% *}
  HI[$b]=${range#* }
  # A batch's gid is derived from its batch id, the convention the coordinator follows.
  GID[$b]=$(psql "$SHOP_URL" -tAX -c "SELECT 'xa-recon-' || left(encode(sha256(convert_to('recon-$(printf '%04d' "$b")', 'UTF8')), 'hex'), 6)")
  [ -n "${LO[$b]}" ] && [ -n "${HI[$b]}" ] && [ -n "${GID[$b]}" ] || { echo "seed: batch $b inserted no orders" >&2; exit 1; }
done
UNDECIDED_GID=${GID[10]}
ABORT_GID=${GID[11]}
COMMIT_GID=${GID[12]}

run_batch() {  # $1 batch number, $2 commit|strand
  local b=$1 mode=$2 gid=${GID[$1]}
  shop <<SQL
BEGIN;
UPDATE public.orders SET status = 'reconciled', updated_at = now()
 WHERE status = 'invoiced' AND id BETWEEN ${LO[$b]} AND ${HI[$b]};
INSERT INTO public.payment_reconciliations (batch_id, gid, order_id, amount, reconciled_at)
SELECT 'recon-' || lpad('$b', 4, '0'), '$gid', id, total, now()
  FROM public.orders
 WHERE status = 'reconciled' AND id BETWEEN ${LO[$b]} AND ${HI[$b]};
PREPARE TRANSACTION '$gid';
SQL
  if [ "$mode" = commit ]; then shop -c "COMMIT PREPARED '$gid'"; fi
}
for b in $(seq 1 9); do run_batch "$b" commit; done
# The final three catch-up batches ran concurrently. Every orders branch voted YES by
# preparing; the oldest of them is what VACUUM's removable cutoff stops at.
run_batch 10 strand
run_batch 11 strand
run_batch 12 strand

prepared_at() {  # $1 url, $2 gid
  psql "$1" -tAX -c "SELECT prepared FROM pg_prepared_xacts WHERE gid = '$2' AND database = current_database()"
}
T10=$(prepared_at "$SHOP_URL" "$UNDECIDED_GID")
T11=$(prepared_at "$SHOP_URL" "$ABORT_GID")
T12=$(prepared_at "$SHOP_URL" "$COMMIT_GID")
[ -n "$T10" ] && [ -n "$T11" ] && [ -n "$T12" ] || { echo "seed: a stranded orders branch is not prepared" >&2; exit 1; }

# The batch's reconciliation lines as the ledger records them. Seen from outside the
# stranded transactions, a committed batch's orders read 'reconciled' and a stranded
# batch's still read 'invoiced', so selecting both states over the range is exactly the
# batch either way.
batch_rows() {  # $1 batch number -> a VALUES list for public.ledger_entries
  local b=$1
  psql "$SHOP_URL" -tAX -v ON_ERROR_STOP=1 -c "
    SELECT string_agg(format('(%L, %L, %s, %s, now())', 'recon-' || lpad('$b', 4, '0'), '${GID[$b]}', id, total), ', ' ORDER BY id)
      FROM public.orders
     WHERE id BETWEEN ${LO[$b]} AND ${HI[$b]} AND status IN ('invoiced','reconciled')"
}

# Each batch posts to a clearing account; a batch's ledger branch updates that account's
# row, so an in-doubt branch holds the row's lock until it is resolved.
account_for() { case $1 in 10) echo card ;; 12) echo wallet ;; *) [ $(($1 % 2)) -eq 1 ] && echo card || echo wallet ;; esac; }

say "the ledger's committed history and the coordinator's journal, anchored on the prepare times"
# The coordinator's registry of every batch it planned.
for b in $(seq 1 12); do
  ledger -c "INSERT INTO recon.batches (batch_id, gid, lo, hi, account) VALUES ('recon-$(printf '%04d' "$b")', '${GID[$b]}', ${LO[$b]}, ${HI[$b]}, '$(account_for "$b")')"
done
# The run that crashed began just before recon-0001.
ledger -c "INSERT INTO recon.xa_decisions (at, branch, event) VALUES (timestamptz '$T10' - make_interval(mins => 45, secs => 30), '$OLD_POD', 'COORDINATOR STARTED')"
for b in $(seq 1 9); do
  gid=${GID[$b]}
  batch="recon-$(printf '%04d' "$b")"
  at="timestamptz '$T10' - make_interval(mins => (10 - $b) * 5)"
  psql "$SHOP_URL" -X -v ON_ERROR_STOP=1 -c "\\copy (SELECT '$batch', '$gid', id, total, $at + make_interval(secs => $SETTLE_SEC + 0.2) FROM public.orders WHERE id BETWEEN ${LO[$b]} AND ${HI[$b]} AND status IN ('invoiced','reconciled') ORDER BY id) TO STDOUT" \
    | ledger -c "\\copy public.ledger_entries (batch_id, gid, order_id, amount, posted_at) FROM STDIN"
  ledger <<SQL
UPDATE public.ledger_accounts SET posted = posted + (SELECT sum(amount) FROM public.ledger_entries WHERE gid = '$gid')
 WHERE account = '$(account_for "$b")';
INSERT INTO public.xa_txn_log VALUES ('$gid', '$batch', 'ledger', 'COMMITTED', $at + make_interval(secs => $SETTLE_SEC + 1.4));
INSERT INTO recon.xa_decisions VALUES
  ($at - interval '0.4 seconds',                   '$batch', '$gid', NULL,     'STARTED'),
  ($at,                                           '$batch', '$gid', 'orders', 'vote=YES'),
  ($at + make_interval(secs => $SETTLE_SEC + 0.3), '$batch', '$gid', 'ledger', 'vote=YES'),
  ($at + make_interval(secs => $SETTLE_SEC + 0.5), '$batch', '$gid', NULL,     'DECISION=COMMIT'),
  ($at + make_interval(secs => $SETTLE_SEC + 1.4), '$batch', '$gid', 'ledger', 'COMMITTED'),
  ($at + make_interval(secs => $SETTLE_SEC + 1.9), '$batch', '$gid', 'orders', 'COMMITTED');
SQL
done
say "the committed batches' records, stamped when the journal says they ran"
for b in $(seq 1 9); do
  shop -c "UPDATE public.payment_reconciliations SET reconciled_at = timestamptz '$T10' - make_interval(mins => (10 - $b) * 5) - interval '0.1 seconds' WHERE batch_id = 'recon-$(printf '%04d' "$b")'"
  shop -c "UPDATE public.orders SET updated_at = timestamptz '$T10' - make_interval(mins => (10 - $b) * 5) - interval '0.1 seconds' WHERE id BETWEEN ${LO[$b]} AND ${HI[$b]} AND status = 'reconciled'"
done

say "the stranded batches settle their invoices for ${SETTLE_SEC}s before their ledger branches"
waited=$(psql "$SHOP_URL" -tAX -c "SELECT greatest(0, ceil($SETTLE_SEC - extract(epoch FROM now() - timestamptz '$T12')))::int + 1")
sleep "$waited"
say "the ledger's side of the stranded batches, in the order the crash left them"
# recon-0012 prepared on the ledger first, then recon-0010, whose YES vote was the last
# thing the coordinator received before it crashed. Each branch posts to its batch's
# clearing account, so each holds that account's row lock while it is in doubt.
for b in 12 10; do
  rows=$(batch_rows "$b")
  [ -n "$rows" ] || { echo "seed: batch $b has no rows to post" >&2; exit 1; }
  ledger <<SQL
BEGIN;
INSERT INTO public.ledger_entries (batch_id, gid, order_id, amount, posted_at) VALUES $rows;
UPDATE public.ledger_accounts SET posted = posted + (SELECT sum(amount) FROM public.ledger_entries WHERE gid = '${GID[$b]}')
 WHERE account = '$(account_for "$b")';
PREPARE TRANSACTION '${GID[$b]}';
SQL
done
L12=$(prepared_at "$LEDGER_URL" "$COMMIT_GID")
L10=$(prepared_at "$LEDGER_URL" "$UNDECIDED_GID")
[ -n "$L12" ] && [ -n "$L10" ] || { echo "seed: a stranded ledger branch is not prepared" >&2; exit 1; }

# Every journal entry falls before the crash, which came just after recon-0010's ledger
# vote (L10). Events between two server-stamped instants are placed at fractions of the
# gap between them, so the order holds however long the seed took between prepares.
between() {  # $1 from, $2 to, $3 fraction -> a timestamptz expression
  echo "(timestamptz '$1' + (timestamptz '$2' - timestamptz '$1') * $3)"
}
# The three workers started together; recon-0011's ledger branch held the clearing
# account's row until it failed, and recon-0010's ledger branch prepared once it was
# released.
NO11=$(between "$L12" "$L10" 0.2)
ABORT11=$(between "$L12" "$L10" 0.4)
COMMIT12=$(between "$L12" "$L10" 0.5)
BACK11=$(between "$L12" "$L10" 0.6)
ledger <<SQL
-- recon-0010: both votes in, no decision journalled before the crash.
INSERT INTO public.xa_txn_log VALUES ('$UNDECIDED_GID', 'recon-0010', 'ledger', 'PREPARED', timestamptz '$L10');
INSERT INTO recon.xa_decisions VALUES
  (timestamptz '$T10' - interval '0.402 seconds', 'recon-0010', '$UNDECIDED_GID', NULL, 'STARTED'),
  (timestamptz '$T10' - interval '0.401 seconds', 'recon-0011', '$ABORT_GID',     NULL, 'STARTED'),
  (timestamptz '$T10' - interval '0.400 seconds', 'recon-0012', '$COMMIT_GID',    NULL, 'STARTED'),
  (timestamptz '$T10', 'recon-0010', '$UNDECIDED_GID', 'orders', 'vote=YES'),
  (timestamptz '$L10', 'recon-0010', '$UNDECIDED_GID', 'ledger', 'vote=YES');
-- recon-0011: the ledger could not prepare and voted NO, so the coordinator journalled
-- ABORT and the ledger's side was rolled back. Nothing was posted.
INSERT INTO public.xa_txn_log VALUES ('$ABORT_GID', 'recon-0011', 'ledger', 'ROLLED BACK', $BACK11);
INSERT INTO recon.xa_decisions VALUES
  (timestamptz '$T11', 'recon-0011', '$ABORT_GID', 'orders', 'vote=YES'),
  ($NO11,              'recon-0011', '$ABORT_GID', 'ledger', 'vote=NO'),
  ($ABORT11,           'recon-0011', '$ABORT_GID', NULL,     'DECISION=ABORT'),
  ($BACK11,            'recon-0011', '$ABORT_GID', 'ledger', 'ROLLED BACK');
-- recon-0012: COMMIT journalled; phase two never started.
INSERT INTO public.xa_txn_log VALUES ('$COMMIT_GID', 'recon-0012', 'ledger', 'PREPARED', timestamptz '$L12');
INSERT INTO recon.xa_decisions VALUES
  (timestamptz '$T12', 'recon-0012', '$COMMIT_GID', 'orders', 'vote=YES'),
  (timestamptz '$L12', 'recon-0012', '$COMMIT_GID', 'ledger', 'vote=YES'),
  ($COMMIT12,          'recon-0012', '$COMMIT_GID', NULL,     'DECISION=COMMIT');
SQL

say "the crashed run's last log lines, for the on-call's crash report"
# Its log as coordinator.py writes it, rebuilt from the same instants as the journal: the last
# catch-up batch it finished, then the three it was running when its pod was evicted. Each
# thread was mid-step at that instant: recon-0012 between journalling COMMIT and phase two,
# recon-0011 between the ledger's rollback and the orders branch's, and recon-0010 between
# logging its decision and journalling it -- so recon-0010 has no decision.
entries=()
entry() { entries+=("($1, ${#entries[@]}, $2)"); }   # a timestamptz expression, a text expression
say_at() { entry "$1" "'$2'"; }
n_of() { psql "$SHOP_URL" -tAX -c "SELECT count(*) FROM public.orders WHERE id BETWEEN ${LO[$1]} AND ${HI[$1]} AND status IN ('invoiced','reconciled')"; }
batch_log() {  # $1 batch number, $2 when it started, $3 when its orders branch prepared
  local b=$1 s=$2 t=$3 name n i
  name="recon-$(printf '%04d' "$b")"
  n=$(n_of "$b")
  say_at "$s" "$name: started: orders ${LO[$b]}..${HI[$b]}, gid ${GID[$b]}, account $(account_for "$b")"
  say_at "$t" "$name: orders branch prepared, vote=YES"
  say_at "$t + interval '10 milliseconds'" "$name: settling $n invoices with the payment provider"
  for ((i = 50; i < n; i += 50)); do say_at "$t + make_interval(secs => $SETTLE_SEC * $i / $n.0)" "$name: settled $i/$n"; done
  say_at "$t + make_interval(secs => $SETTLE_SEC)" "$name: settled $n/$n"
  say_at "$t + make_interval(secs => $SETTLE_SEC + 0.01)" "$name: preparing the ledger branch, $n entries to $(account_for "$b")"
}
at9="(timestamptz '$T10' - make_interval(mins => 5))"
say_at "$at9 - interval '0.45 seconds'" "backlog: 1 batch(es): recon-0009"
batch_log 9 "$at9 - interval '0.4 seconds'" "$at9"
say_at "$at9 + make_interval(secs => $SETTLE_SEC + 0.3)" "recon-0009: ledger vote=YES; deciding COMMIT"
say_at "$at9 + make_interval(secs => $SETTLE_SEC + 0.5)" "recon-0009: decision COMMIT journalled"
say_at "$at9 + make_interval(secs => $SETTLE_SEC + 1.9)" "recon-0009: committed on both resource managers"
say_at "$at9 + make_interval(secs => $SETTLE_SEC + 1.95)" "backlog reconciled"
say_at "timestamptz '$T10' - interval '0.45 seconds'" "backlog: 3 batch(es): recon-0010, recon-0011, recon-0012"
batch_log 10 "timestamptz '$T10' - interval '0.402 seconds'" "timestamptz '$T10'"
batch_log 11 "timestamptz '$T10' - interval '0.401 seconds'" "timestamptz '$T11'"
batch_log 12 "timestamptz '$T10' - interval '0.400 seconds'" "timestamptz '$T12'"
say_at "timestamptz '$L12'" "recon-0012: ledger vote=YES; deciding COMMIT"
entry "$NO11" "'recon-0011: ledger branch failed to prepare: consuming input failed: could not receive data from server: Connection reset by peer'"
say_at "$NO11 + interval '1 millisecond'" "recon-0011: ledger vote=NO; deciding ABORT"
say_at "$ABORT11" "recon-0011: decision ABORT journalled"
say_at "$COMMIT12" "recon-0012: decision COMMIT journalled"
say_at "timestamptz '$L10'" "recon-0010: ledger vote=YES; deciding COMMIT"
IFS=,; values="${entries[*]}"; unset IFS
{
  echo "Saved by payments-platform on-call from $OLD_POD, evicted at $(psql "$LEDGER_URL" -tAX -c "SELECT to_char((timestamptz '$L10' + interval '0.2 seconds') AT TIME ZONE 'UTC', 'HH24:MI:SS\"Z\"')") (the node was low on resource: memory), before the pod was cleaned up. The last lines of its log:"
  echo
  psql "$LEDGER_URL" -tAX -v ON_ERROR_STOP=1 -c "SELECT to_char(t AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') || ' ' || m FROM (VALUES $values) AS l(t, k, m) ORDER BY t, k"
} > "$CRASH_REPORT"

say "checking the crash state"
count() { psql "$1" -tAX -c "$2"; }
[ "$(count "$SHOP_URL" "SELECT count(*) FROM pg_prepared_xacts WHERE database = current_database()")" -eq 3 ] \
  || { echo "seed: expected three prepared orders branches" >&2; exit 1; }
[ "$(count "$LEDGER_URL" "SELECT count(*) FROM pg_prepared_xacts WHERE database = current_database()")" -eq 2 ] \
  || { echo "seed: expected two prepared ledger branches" >&2; exit 1; }
[ "$(count "$LEDGER_URL" "SELECT count(*) FROM public.ledger_entries WHERE gid IN ('$COMMIT_GID', '$ABORT_GID', '$UNDECIDED_GID')")" -eq 0 ] \
  || { echo "seed: a stranded batch is visible on the ledger" >&2; exit 1; }
[ "$(count "$LEDGER_URL" "SELECT count(*) FROM recon.xa_decisions WHERE gid = '$UNDECIDED_GID' AND event LIKE 'DECISION=%'")" -eq 0 ] \
  || { echo "seed: recon-0010 must have no journalled decision" >&2; exit 1; }
[ "$(count "$LEDGER_URL" "SELECT count(*) FROM recon.xa_decisions WHERE at > timestamptz '$L10'")" -eq 0 ] \
  || { echo "seed: the journal continues past the crash" >&2; exit 1; }
[ "$(count "$LEDGER_URL" "SELECT count(*) FROM recon.batches")" -eq 12 ] \
  || { echo "seed: expected twelve planned batches" >&2; exit 1; }
[ "$(count "$LEDGER_URL" "SELECT count(*) FROM recon.backlog")" -eq 0 ] \
  || { echo "seed: the backlog must be empty until the coordinator recovers" >&2; exit 1; }

say "an hour of storefront traffic against the order history"
# Only states the stranded branches never hold, so none of these statements waits on them.
for r in $(seq 1 "$CHURN_ROUNDS"); do
  shop -c "UPDATE public.orders SET updated_at = now() WHERE status IN ('delivered','shipped','cancelled') AND id % 3 = $((r % 3))"
done

say "done: $(psql "$SHOP_URL" -tAX -c "SELECT n_live_tup || ' live, ' || n_dead_tup || ' dead in public.orders' FROM pg_stat_user_tables WHERE relname = 'orders'")"
