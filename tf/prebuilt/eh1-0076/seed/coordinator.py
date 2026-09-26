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

"""payments-recon: the reconciliation coordinator.

Reconciles invoiced orders with the ledger in batches. Each batch is one two-phase commit
across the orders database and the ledger, presumed abort: a batch's decision is
journalled in the ledger database before phase two, and a batch with no journalled
decision was never committed.

The invoicing service queues batches in recon.backlog, and up to WORKERS of them run at
once. A batch's gid is derived from its batch id. Each invoice is settled with the payment
provider before the ledger branch is prepared; the provider takes SETTLE_PER_SEC a second.

At start the coordinator journals its start and carries on from the run before it.
"""

import datetime
import hashlib
import os
import time
from concurrent.futures import ThreadPoolExecutor

import psycopg
from psycopg import sql


def dsn(prefix, host, dbname):
    return {
        "host": os.environ.get(f"{prefix}_HOST", host),
        "port": int(os.environ.get(f"{prefix}_PORT", "5432")),
        "user": os.environ.get(f"{prefix}_USER", "postgres"),
        "password": os.environ[f"{prefix}_PASSWORD"],
        "dbname": dbname,
        "application_name": "payments-recon",
        "connect_timeout": 10,
    }


SHOP = dsn("SHOP", "shop-rw.orders-db.svc", "shop")
LEDGER = dsn("LEDGER", "ledger-rw.ledger.svc", "ledger")
POD = os.environ.get("POD_NAME", "payments-recon")
WORKERS = int(os.environ.get("WORKERS", "3"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "300"))
SETTLE_PER_SEC = float(os.environ.get("SETTLE_PER_SEC", "2"))


def log(message):
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"{stamp} {message}", flush=True)


def gid_for(batch):
    return "xa-recon-" + hashlib.sha256(batch.encode()).hexdigest()[:6]


def journal(batch, gid, branch, event):
    with psycopg.connect(**LEDGER, autocommit=True) as conn:
        conn.execute(
            "INSERT INTO recon.xa_decisions (at, batch_id, gid, branch, event) "
            "VALUES (clock_timestamp(), %s, %s, %s, %s)",
            (batch, gid, branch, event),
        )


def branch_state(batch, gid, state):
    """The ledger branch's state, as the ledger's own xa_txn_log reports it."""
    with psycopg.connect(**LEDGER, autocommit=True) as conn:
        conn.execute(
            "INSERT INTO public.xa_txn_log (gid, batch_id, branch, state, updated_at) "
            "VALUES (%s, %s, 'ledger', %s, clock_timestamp()) "
            "ON CONFLICT (gid) DO UPDATE SET state = EXCLUDED.state, updated_at = EXCLUDED.updated_at",
            (gid, batch, state),
        )


def resolve(params, verb, gid):
    with psycopg.connect(**params, autocommit=True) as conn:
        conn.execute(sql.SQL(verb + " {}").format(sql.Literal(gid)))


def recover():
    """Carry on from the run before this one."""
    with psycopg.connect(**LEDGER) as conn:
        begun = conn.execute(
            """
            SELECT b.batch_id, b.lo, b.hi, b.account,
                   EXISTS (SELECT 1 FROM recon.xa_decisions d
                            WHERE d.gid = b.gid AND d.branch IS NULL AND d.event LIKE 'DECISION=%%')
              FROM recon.batches b
             WHERE EXISTS (SELECT 1 FROM recon.xa_decisions d WHERE d.gid = b.gid)
               AND NOT EXISTS (SELECT 1 FROM recon.xa_decisions d
                                WHERE d.gid = b.gid AND d.branch = 'orders'
                                  AND d.event IN ('COMMITTED', 'ROLLED BACK'))
               AND NOT EXISTS (SELECT 1 FROM recon.batches r WHERE r.requeue_of = b.batch_id)
               AND b.batch_id NOT IN (SELECT batch_id FROM recon.backlog)
             ORDER BY b.batch_id
            """
        ).fetchall()
        requeued = 0
        for batch, lo, hi, account, decided in begun:
            if decided:
                continue
            number = conn.execute(
                "SELECT coalesce(max(substring(batch_id FROM 7)::int), 0) + 1 FROM recon.batches"
            ).fetchone()[0]
            again = f"recon-{number:04d}"
            conn.execute(
                "INSERT INTO recon.batches (batch_id, gid, lo, hi, account, requeue_of) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (again, gid_for(again), lo, hi, account, batch),
            )
            conn.execute("INSERT INTO recon.backlog (batch_id) VALUES (%s)", (again,))
            requeued += 1
        conn.commit()
    log(f"recovery: {len(begun)} batch(es) begun by an earlier run, {requeued} re-queued")


def run_batch(batch, gid, lo, hi, account):
    journal(batch, gid, None, "STARTED")
    log(f"{batch}: started: orders {lo}..{hi}, gid {gid}, account {account}")

    # Phase one, orders.
    try:
        with psycopg.connect(**SHOP, autocommit=True) as conn:
            conn.execute("BEGIN")
            conn.execute(
                "UPDATE public.orders SET status = 'reconciled', updated_at = now() "
                "WHERE status = 'invoiced' AND id BETWEEN %s AND %s",
                (lo, hi),
            )
            conn.execute(
                "INSERT INTO public.payment_reconciliations (batch_id, gid, order_id, amount, reconciled_at) "
                "SELECT %s, %s, id, total, now() FROM public.orders "
                "WHERE status = 'reconciled' AND id BETWEEN %s AND %s",
                (batch, gid, lo, hi),
            )
            conn.execute(sql.SQL("PREPARE TRANSACTION {}").format(sql.Literal(gid)))
    except psycopg.Error as exc:
        log(f"{batch}: orders branch failed before it could vote: {exc}")
        journal(batch, gid, "orders", "FAILED")
        log(f"{batch}: deciding ABORT")
        journal(batch, gid, None, "DECISION=ABORT")
        log(f"{batch}: decision ABORT journalled; its invoices return in the nightly window")
        return
    journal(batch, gid, "orders", "vote=YES")
    log(f"{batch}: orders branch prepared, vote=YES")

    # Phase one, ledger. Seen from outside the prepared orders branch, the batch's
    # orders still read 'invoiced'.
    with psycopg.connect(**SHOP, autocommit=True) as conn:
        rows = conn.execute(
            "SELECT id, total FROM public.orders WHERE id BETWEEN %s AND %s "
            "AND status IN ('invoiced', 'reconciled') ORDER BY id",
            (lo, hi),
        ).fetchall()
    # The provider settles one invoice at a time. Nothing is held open meanwhile except the
    # prepared orders branch, which waits for the decision.
    log(f"{batch}: settling {len(rows)} invoices with the payment provider")
    for i, _ in enumerate(rows, 1):
        time.sleep(1 / SETTLE_PER_SEC)
        if i % 50 == 0 or i == len(rows):
            log(f"{batch}: settled {i}/{len(rows)}")
    log(f"{batch}: preparing the ledger branch, {len(rows)} entries to {account}")
    try:
        with psycopg.connect(**LEDGER, autocommit=True) as conn:
            conn.execute("BEGIN")
            with conn.cursor() as cur:
                cur.executemany(
                    "INSERT INTO public.ledger_entries (batch_id, gid, order_id, amount, posted_at) "
                    "VALUES (%s, %s, %s, %s, now())",
                    [(batch, gid, order_id, total) for order_id, total in rows],
                )
            conn.execute(
                "UPDATE public.ledger_accounts SET posted = posted + %s WHERE account = %s",
                (sum(total for _, total in rows), account),
            )
            conn.execute(sql.SQL("PREPARE TRANSACTION {}").format(sql.Literal(gid)))
        vote = "YES"
        branch_state(batch, gid, "PREPARED")
    except psycopg.Error as exc:  # the ledger could not prepare: that is a NO vote
        log(f"{batch}: ledger branch failed to prepare: {exc}")
        vote = "NO"
    journal(batch, gid, "ledger", f"vote={vote}")

    decision = "COMMIT" if vote == "YES" else "ABORT"
    log(f"{batch}: ledger vote={vote}; deciding {decision}")
    journal(batch, gid, None, f"DECISION={decision}")
    log(f"{batch}: decision {decision} journalled")

    # Phase two.
    verb = "COMMIT PREPARED" if decision == "COMMIT" else "ROLLBACK PREPARED"
    done = "COMMITTED" if decision == "COMMIT" else "ROLLED BACK"
    if vote == "YES":
        resolve(LEDGER, verb, gid)
    journal(batch, gid, "ledger", done)
    branch_state(batch, gid, done)
    try:
        resolve(SHOP, verb, gid)
    except psycopg.Error as exc:
        journal(batch, gid, "orders", "MISSING AT PHASE TWO")
        log(f"{batch}: HEURISTIC HAZARD: the orders branch was not there to {verb.lower()}: {exc}")
        return
    journal(batch, gid, "orders", done)
    log(f"{batch}: {done.lower()} on both resource managers")


def start():
    log(f"payments-recon coordinator starting on {POD}")
    log(f"resource managers: {os.environ.get('RESOURCE_MANAGERS', '')}")
    log(f"decision journal: {os.environ.get('JOURNAL', '')}")
    log(f"protocol: {os.environ.get('PROTOCOL', '')}")
    journal(None, None, POD, "COORDINATOR STARTED")
    recover()


def serve():
    while True:
        with psycopg.connect(**LEDGER) as conn:
            backlog = conn.execute(
                "DELETE FROM recon.backlog q USING recon.batches b WHERE b.batch_id = q.batch_id "
                "RETURNING b.batch_id, b.gid, b.lo, b.hi, b.account"
            ).fetchall()
            conn.commit()
        if backlog:
            backlog.sort()
            log(f"backlog: {len(backlog)} batch(es): {', '.join(b[0] for b in backlog)}")
            with ThreadPoolExecutor(max_workers=WORKERS) as pool:
                for _ in pool.map(lambda b: run_batch(*b), backlog):
                    pass
            log("backlog reconciled")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    for attempt in range(1, 31):
        try:
            start()
            break
        except psycopg.Error as exc:  # a resource manager not reachable yet
            log(f"start attempt {attempt} failed: {exc}; retrying in 10s")
            time.sleep(10)
    else:
        raise SystemExit("payments-recon: could not reach the resource managers")
    serve()
