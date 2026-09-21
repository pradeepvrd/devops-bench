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

"""HTTP status server and continuous monitor runner for eh1-0031 verifier."""

from __future__ import annotations

import http.server
import json
import signal
import sys
import threading
import time

sys.path.insert(0, "/oracle")
sys.path.insert(0, "/checks")
import challenge
import verify

CACHED_STATUS_BODY = b'{"ready": false}\n'


def status_cache_worker():
    global CACHED_STATUS_BODY
    while True:
        try:
            results = verify.get_status()
            CACHED_STATUS_BODY = (json.dumps(results, sort_keys=True) + "\n").encode("utf-8")
        except Exception as exc:
            print(f"status_cache_worker error: {exc}", file=sys.stderr, flush=True)
        time.sleep(1.0)


class StatusHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/status":
            body = CACHED_STATUS_BODY
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        sys.stderr.write(
            f"{self.address_string()} - - [{self.log_date_time_string()}] {format % args}\n"
        )


def orders_worker():
    time.sleep(5)
    while True:
        try:
            prior_base = verify._read_json(challenge.STATE / "prior-month-rows-baseline.json", None)
            if prior_base is not None:
                try:
                    current_prior = verify.prior_month_rows_count()
                    raw_diff = max(0, int(prior_base) - int(current_prior))
                    pg_missing = raw_diff if raw_diff > 50 else 0
                    tmp = challenge.STATE / "pg-missing.json.tmp"
                    tmp.write_text(json.dumps(pg_missing))
                    tmp.replace(challenge.STATE / "pg-missing.json")
                except Exception:
                    pass
            marker_file = challenge.STATE / "marker-delivered.json"
            if not marker_file.exists() or not verify._read_json(marker_file, False):
                try:
                    res = challenge.marker_challenge(budget=18.0)
                    if res.get("delivered"):
                        tmp = challenge.STATE / "marker-delivered.json.tmp"
                        tmp.write_text(json.dumps(True))
                        tmp.replace(marker_file)
                except Exception:
                    pass
        except Exception as exc:
            print(f"orders_worker error: {exc}", file=sys.stderr, flush=True)
        time.sleep(10)


def main():
    def timed_out(*_):
        raise TimeoutError("monitor received an unexpected alarm")

    signal.signal(signal.SIGALRM, timed_out)

    print("Starting cdc-observer orders worker...", flush=True)
    t_orders = threading.Thread(target=orders_worker, daemon=True)
    t_orders.start()

    t_cache = threading.Thread(target=status_cache_worker, daemon=True)
    t_cache.start()

    print("Starting cdc-observer HTTP status server on 0.0.0.0:8080...", flush=True)
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), StatusHandler)
    t_server = threading.Thread(target=server.serve_forever, daemon=True)
    t_server.start()
    print("Started cdc-observer HTTP status server on 0.0.0.0:8080", flush=True)

    print("Starting continuous monitor...", flush=True)
    challenge.monitor()


if __name__ == "__main__":
    main()
