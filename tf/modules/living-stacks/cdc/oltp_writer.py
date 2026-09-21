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
import multiprocessing
import os
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
from psycopg import OperationalError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("oltp-writer")

SEED = int(os.environ.get("SEED", "42"))
PROFILE_PATH = os.environ.get("PROFILE_PATH", "/profile/profile.json")
PGHOST = os.environ.get("PGHOST", "shop-rw")
PGPORT = os.environ.get("PGPORT", "5432")
PGDATABASE = os.environ.get("PGDATABASE", "shop")
PGUSER = os.environ.get("PGUSER", "app")
PGPASSWORD = os.environ.get("PGPASSWORD", "")
STATUS_PORT = int(os.environ.get("STATUS_PORT", "8080"))

INITIAL_CUSTOMERS = 200
INITIAL_PRODUCTS = 50

CATEGORIES = ["electronics", "apparel", "home", "beauty", "sports", "toys", "grocery", "books"]
TIERS = ["standard", "silver", "gold", "platinum"]
ORDER_STATUSES = ["pending", "processing", "shipped", "delivered", "cancelled"]
STATUS_FORWARD = {
    "pending": ["processing", "cancelled"],
    "processing": ["shipped", "cancelled"],
    "shipped": ["delivered"],
}

_SLOT_STATE_LOCK = threading.Lock()
_SLOT_STATE = {
    "baseline_restart_lsn_num": None,
    "baseline_flush_lsn_num": None,
    "previous_flush_lsn_num": None,
    "violated": False,
    "advanced_since_baseline": False,
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


def diurnal_multiplier(elapsed_seconds, day_length_minutes, amplitude):
    if day_length_minutes <= 0:
        return 1.0
    day_length_seconds = day_length_minutes * 60.0
    phase = (elapsed_seconds % day_length_seconds) / day_length_seconds
    wave = math.sin(2 * math.pi * phase - math.pi / 2)
    return max(0.05, 1.0 + amplitude * wave)


def connect(profile, app_name=None):
    max_attempts = profile.get("db_retry", {}).get("max_attempts", 0)
    backoff_seconds = profile.get("db_retry", {}).get("backoff_seconds", 5)
    attempt = 0
    kwargs = {
        "host": PGHOST,
        "port": PGPORT,
        "dbname": PGDATABASE,
        "user": PGUSER,
        "password": PGPASSWORD,
        "autocommit": True,
        "connect_timeout": 10,
    }
    if app_name:
        kwargs["application_name"] = app_name
    while True:
        attempt += 1
        try:
            conn = psycopg.connect(**kwargs)
            log.info(
                "connected to postgres at %s:%s/%s app_name=%s",
                PGHOST,
                PGPORT,
                PGDATABASE,
                app_name,
            )
            return conn
        except OperationalError as exc:
            if max_attempts and attempt >= max_attempts:
                log.error("postgres connect failed after %d attempts: %s, giving up", attempt, exc)
                raise
            log.warning(
                "postgres connect failed (attempt %d): %s, retrying in %ss",
                attempt,
                exc,
                backoff_seconds,
            )
            time.sleep(backoff_seconds)


def seed_if_empty(conn, rng):
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM customers")
        (customer_count,) = cur.fetchone()
        cur.execute("SELECT count(*) FROM products")
        (product_count,) = cur.fetchone()

    if customer_count > 0 or product_count > 0:
        log.info(
            "tables not empty (customers=%d products=%d), skipping seed",
            customer_count,
            product_count,
        )
        return

    log.info("seeding %d customers and %d products", INITIAL_CUSTOMERS, INITIAL_PRODUCTS)
    with conn.cursor() as cur:
        for i in range(INITIAL_CUSTOMERS):
            cur.execute(
                "INSERT INTO customers (name, email, tier) VALUES (%s, %s, %s)",
                (
                    f"seed-customer-{SEED}-{i}",
                    f"seed-customer-{SEED}-{i}@example.test",
                    rng.choice(TIERS),
                ),
            )
        for i in range(INITIAL_PRODUCTS):
            cur.execute(
                "INSERT INTO products (name, category, price, stock) VALUES (%s, %s, %s, %s)",
                (
                    f"seed-product-{SEED}-{i}",
                    rng.choice(CATEGORIES),
                    round(rng.uniform(2.5, 499.99), 2),
                    rng.randint(10, 500),
                ),
            )
    log.info("seed complete")


def load_ids(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM customers ORDER BY id")
        customer_ids = [r[0] for r in cur.fetchall()]
        cur.execute("SELECT id FROM products ORDER BY id")
        product_ids = [r[0] for r in cur.fetchall()]
        cur.execute(
            "SELECT EXISTS (SELECT 1 FROM information_schema.tables "
            "WHERE table_schema = 'public' AND table_name = 'order_adjustments')"
        )
        (has_adjustments,) = cur.fetchone()
    return customer_ids, product_ids, bool(has_adjustments)


def op_insert_order(conn, rng, seq, customer_ids, product_ids, zipf_table, has_adjustments):
    if not customer_ids or not product_ids:
        return
    customer_id = customer_ids[pick_zipf(rng, zipf_table)]
    item_count = rng.randint(1, 4)
    with conn.transaction(), conn.cursor() as cur:
        cur.execute(
            "INSERT INTO orders (customer_id, status, total) VALUES (%s, 'pending', 0) "
            "RETURNING id",
            (customer_id,),
        )
        (order_id,) = cur.fetchone()
        total = 0.0
        for _ in range(item_count):
            product_id = rng.choice(product_ids)
            cur.execute("SELECT price FROM products WHERE id = %s", (product_id,))
            row = cur.fetchone()
            if row is None:
                continue
            price = float(row[0])
            qty = rng.randint(1, 5)
            cur.execute(
                "INSERT INTO order_items (order_id, product_id, qty, unit_price) "
                "VALUES (%s, %s, %s, %s)",
                (order_id, product_id, qty, price),
            )
            total += price * qty
        cur.execute("UPDATE orders SET total = %s WHERE id = %s", (round(total, 2), order_id))
        if has_adjustments:
            adj_id = f"adj-{SEED}-{order_id}-{seq}"
            reason = rng.choice(["shipping_credit", "service_credit", "tax_correction"])
            amount = round(rng.uniform(-5.0, 5.0), 2)
            cur.execute(
                "INSERT INTO order_adjustments (id, order_id, reason, amount) "
                "VALUES (%s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                (adj_id, order_id, reason, amount),
            )


def op_update_order_status(conn, rng):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id, status FROM orders WHERE status IN ('pending','processing','shipped') "
            "ORDER BY random() LIMIT 1"
        )
        row = cur.fetchone()
        if row is None:
            return
        order_id, status = row
        choices = STATUS_FORWARD.get(status)
        if not choices:
            return
        new_status = rng.choice(choices)
        cur.execute(
            "UPDATE orders SET status = %s, updated_at = now() WHERE id = %s",
            (new_status, order_id),
        )


def op_update_stock(conn, rng, product_ids):
    if not product_ids:
        return
    product_id = rng.choice(product_ids)
    delta = rng.randint(-20, 20)
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE products SET stock = GREATEST(0, stock + %s) WHERE id = %s",
            (delta, product_id),
        )


def op_new_customer(conn, rng, seq, customer_ids):
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO customers (name, email, tier) VALUES (%s, %s, %s) RETURNING id",
            (f"customer-{SEED}-{seq}", f"customer-{SEED}-{seq}@example.test", rng.choice(TIERS)),
        )
        (new_id,) = cur.fetchone()
        customer_ids.append(new_id)


def op_update_customer(conn, rng, customer_ids, zipf_table):
    if not customer_ids:
        return
    customer_id = customer_ids[pick_zipf(rng, zipf_table)]
    with conn.cursor() as cur:
        if rng.random() < 0.2:
            new_tier = rng.choice(TIERS)
            cur.execute(
                "UPDATE customers SET tier = %s, updated_at = now() WHERE id = %s",
                (new_tier, customer_id),
            )
        else:
            cur.execute(
                "UPDATE customers SET updated_at = now() WHERE id = %s",
                (customer_id,),
            )


def op_delete_stale_order(conn, rng):
    with conn.transaction(), conn.cursor() as cur:
        cur.execute(
            "SELECT id FROM orders WHERE status IN ('delivered','cancelled') "
            "ORDER BY random() LIMIT 1"
        )
        row = cur.fetchone()
        if row is None:
            return
        (order_id,) = row
        cur.execute("DELETE FROM order_items WHERE order_id = %s", (order_id,))
        cur.execute("DELETE FROM orders WHERE id = %s", (order_id,))


OP_NAMES = [
    "insert_order",
    "update_order_status",
    "update_stock",
    "new_customer",
    "update_customer",
    "delete_stale_order",
]


def run_op(conn, op_name, rng, seq, customer_ids, product_ids, zipf_table, has_adjustments):
    if op_name == "insert_order":
        op_insert_order(conn, rng, seq, customer_ids, product_ids, zipf_table, has_adjustments)
    elif op_name == "update_order_status":
        op_update_order_status(conn, rng)
    elif op_name == "update_stock":
        op_update_stock(conn, rng, product_ids)
    elif op_name == "new_customer":
        op_new_customer(conn, rng, seq, customer_ids)
    elif op_name == "update_customer":
        op_update_customer(conn, rng, customer_ids, zipf_table)
    elif op_name == "delete_stale_order":
        op_delete_stale_order(conn, rng)


def query_db_telemetry():
    try:
        with (
            psycopg.connect(
                host=PGHOST,
                port=PGPORT,
                dbname=PGDATABASE,
                user=PGUSER,
                password=PGPASSWORD,
                autocommit=True,
                connect_timeout=4,
            ) as conn,
            conn.cursor() as cur,
        ):
            cur.execute(
                "SELECT count(*)::int FROM pg_stat_activity WHERE datname = %s AND usename = %s",
                (PGDATABASE, PGUSER),
            )
            (active_conns,) = cur.fetchone()

            cur.execute(
                "SELECT count(*)::int, "
                "COALESCE(bool_or(active), false), "
                "MAX((restart_lsn - '0/0'::pg_lsn)::bigint), "
                "MAX((confirmed_flush_lsn - '0/0'::pg_lsn)::bigint), "
                "COALESCE(MAX(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint), 0) "
                "FROM pg_replication_slots WHERE slot_name = 'debezium'"
            )
            slot_count, slot_active, restart_num, flush_num, retained_bytes = cur.fetchone()
            slot_exists = slot_count > 0

            with _SLOT_STATE_LOCK:
                if slot_exists and restart_num is not None and flush_num is not None:
                    if _SLOT_STATE["baseline_restart_lsn_num"] is None:
                        _SLOT_STATE["baseline_restart_lsn_num"] = restart_num
                        _SLOT_STATE["baseline_flush_lsn_num"] = flush_num
                        _SLOT_STATE["previous_flush_lsn_num"] = flush_num
                    else:
                        if flush_num < _SLOT_STATE["previous_flush_lsn_num"]:
                            _SLOT_STATE["violated"] = True
                        _SLOT_STATE["previous_flush_lsn_num"] = flush_num
                        if restart_num > _SLOT_STATE["baseline_restart_lsn_num"]:
                            _SLOT_STATE["advanced_since_baseline"] = True
                elif _SLOT_STATE["baseline_restart_lsn_num"] is not None:
                    _SLOT_STATE["violated"] = True

                slot_preserved = (
                    _SLOT_STATE["baseline_restart_lsn_num"] is not None
                    and not _SLOT_STATE["violated"]
                )
                slot_advanced = _SLOT_STATE["advanced_since_baseline"]

            cur.execute(
                "SELECT count(*)::int FROM orders WHERE created_at >= now() - interval '2 minutes'"
            )
            (recent_orders_2m,) = cur.fetchone()

            cur.execute("SELECT count(*)::int FROM orders")
            (total_orders,) = cur.fetchone()

            cur.execute(
                "SELECT EXISTS (SELECT 1 FROM information_schema.tables "
                "WHERE table_schema = 'public' AND table_name = 'order_adjustments')"
            )
            (has_adj,) = cur.fetchone()
            total_adjustments = 0
            if has_adj:
                cur.execute("SELECT count(*)::int FROM order_adjustments")
                (total_adjustments,) = cur.fetchone()

            return {
                "status": "ok",
                "active_app_connections": active_conns,
                "debezium_slot_exists": slot_exists,
                "debezium_slot_active": bool(slot_active),
                "slot_preserved": slot_preserved,
                "slot_advanced": slot_advanced,
                "slot_retained_bytes": int(retained_bytes or 0),
                "recent_orders_2m": recent_orders_2m,
                "total_orders": total_orders,
                "total_adjustments": total_adjustments,
            }
    except Exception as exc:
        return {
            "status": "error",
            "error": str(exc),
            "active_app_connections": 0,
            "debezium_slot_exists": False,
            "debezium_slot_active": False,
            "slot_preserved": False,
            "slot_advanced": False,
            "slot_retained_bytes": 0,
            "recent_orders_2m": 0,
            "total_orders": 0,
            "total_adjustments": 0,
        }


def slot_monitor_loop():
    while True:
        query_db_telemetry()
        time.sleep(2.0)


def start_status_server(profile, get_active_workers_fn):
    class StatusHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/status", "/status/"):
                self.send_response(404)
                self.end_headers()
                return
            db_info = query_db_telemetry()
            payload = {
                "status": "ok",
                "active_workers": get_active_workers_fn(),
                "profile": {
                    "connection_workers": profile.get("connection_workers", 1),
                    "db_retry_backoff_seconds": profile.get("db_retry", {}).get(
                        "backoff_seconds", 5
                    ),
                },
                "db": db_info,
            }
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
    log.info("started oltp-writer status server on 0.0.0.0:%d/status", STATUS_PORT)
    return server


def worker_main(worker_id=0):
    profile = load_profile(PROFILE_PATH)
    rng = random.Random(SEED + worker_id)
    app_name = f"oltp-writer/{worker_id}"

    conn = connect(profile, app_name=app_name)
    if worker_id == 0:
        seed_if_empty(conn, rng)
    customer_ids, product_ids, has_adjustments = load_ids(conn)
    zipf_table = build_zipf_table(max(1, len(customer_ids)), profile["hot_customer_zipf_alpha"])

    op_counts = {k: 0 for k in OP_NAMES}
    seq = worker_id * 1000000
    burst_until = 0.0
    start = time.monotonic()
    last_heartbeat = start
    last_minute_tick = start

    log.info(
        "starting oltp-writer worker=%d seed=%s db=%s/%s profile=%s",
        worker_id,
        SEED + worker_id,
        PGHOST,
        PGDATABASE,
        PROFILE_PATH,
    )

    while True:
        loop_start = time.monotonic()
        elapsed = loop_start - start

        if loop_start - last_minute_tick >= 60.0:
            last_minute_tick = loop_start
            if rng.random() < profile["batch_burst"]["prob_per_minute"]:
                burst_until = loop_start + 5.0
                log.info("batch burst triggered, size=%d", profile["batch_burst"]["size"])

        multiplier = diurnal_multiplier(
            elapsed, profile["day_length_minutes"], profile["diurnal_amplitude"]
        )
        target_ops = max(0.1, profile["base_ops_per_sec"] * multiplier)
        sleep_interval = 1.0 / target_ops

        ops_this_tick = [pick_weighted(rng, profile["op_mix"])]
        if loop_start < burst_until:
            ops_this_tick = [
                pick_weighted(rng, profile["op_mix"]) for _ in range(profile["batch_burst"]["size"])
            ]

        for op_name in ops_this_tick:
            seq += 1
            try:
                run_op(
                    conn, op_name, rng, seq, customer_ids, product_ids, zipf_table, has_adjustments
                )
                op_counts[op_name] += 1
                if len(zipf_table) != len(customer_ids) and customer_ids:
                    zipf_table = build_zipf_table(
                        len(customer_ids), profile["hot_customer_zipf_alpha"]
                    )
            except OperationalError as exc:
                log.warning("db error on %s: %s, reconnecting", op_name, exc)
                with contextlib.suppress(Exception):
                    conn.close()
                conn = connect(profile, app_name=app_name)
                customer_ids, product_ids, has_adjustments = load_ids(conn)
            except Exception as exc:
                log.warning("unexpected error on %s: %s", op_name, exc)

        now = time.monotonic()
        if now - last_heartbeat >= 30:
            log.info(
                "heartbeat worker=%d target_ops_per_sec=%.2f total=%s customers=%d",
                worker_id,
                target_ops,
                dict(op_counts),
                len(customer_ids),
            )
            last_heartbeat = now

        elapsed_loop = time.monotonic() - loop_start
        remaining = sleep_interval - elapsed_loop
        if remaining > 0:
            time.sleep(remaining)


def run_supervised_worker(worker_id):
    while True:
        try:
            worker_main(worker_id)
        except Exception as exc:
            log.exception("fatal error in worker %d, restarting in 5s: %s", worker_id, exc)
            time.sleep(5)


def main():
    profile = load_profile(PROFILE_PATH)
    count = int(profile.get("connection_workers", 1))
    if count < 1 or count > 32:
        raise ValueError("connection_workers must be between 1 and 32")

    if count == 1:
        monitor_thread = threading.Thread(target=slot_monitor_loop, daemon=True)
        monitor_thread.start()
        start_status_server(profile, lambda: 1)
        run_supervised_worker(0)
    else:
        log.info("starting %d supervised OLTP worker processes", count)
        workers = [
            multiprocessing.Process(target=run_supervised_worker, args=(i,), daemon=True)
            for i in range(count)
        ]
        for w in workers:
            w.start()
        monitor_thread = threading.Thread(target=slot_monitor_loop, daemon=True)
        monitor_thread.start()
        start_status_server(profile, lambda: sum(1 for w in workers if w.is_alive()))
        for w in workers:
            w.join()


if __name__ == "__main__":
    main()
