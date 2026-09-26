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
import logging
import os
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("storefront-status")

NAMESPACE = os.environ.get("NAMESPACE", "storefront")
FRONTEND_URL = os.environ.get(
    "FRONTEND_URL",
    f"http://frontend-proxy.{NAMESPACE}.svc.cluster.local:8080",
)
FLAGD_URL = os.environ.get(
    "FLAGD_URL",
    f"http://flagd.{NAMESPACE}.svc.cluster.local:8016",
)
STATUS_PORT = int(os.environ.get("STATUS_PORT", "8080"))

ADDRESS = {
    "streetAddress": "1600 Amphitheatre Parkway",
    "state": "CA",
    "country": "United States",
    "city": "Mountain View",
    "zipCode": "94043",
}
ITEM = {"productId": "0PUK6V6EV0", "quantity": 1}


def post_json(base, path, body, timeout=8):
    req = Request(
        base + path,
        json.dumps(body).encode("utf-8"),
        {"Content-Type": "application/json"},
    )
    for attempt in range(2):
        try:
            with urlopen(req, timeout=timeout) as resp:
                raw = resp.read(65537)
                if resp.status != 200 or len(raw) > 65536:
                    raise RuntimeError(f"unexpected HTTP status {resp.status}")
                return json.loads(raw)
        except (HTTPError, URLError, TimeoutError) as exc:
            if attempt == 0:
                time.sleep(2.0)
                continue
            raise RuntimeError(f"request failed ({type(exc).__name__})") from exc


def exact_items(items):
    return (
        isinstance(items, list)
        and len(items) == 1
        and isinstance(items[0], dict)
        and items[0].get("productId") == ITEM["productId"]
        and type(items[0].get("quantity")) is int
        and items[0]["quantity"] == ITEM["quantity"]
    )


def run_synthetic_checkout():
    user = str(uuid.uuid4())
    try:
        cart = post_json(FRONTEND_URL, "/api/cart", {"userId": user, "item": ITEM})
        cart_ok = bool(cart.get("userId") == user and exact_items(cart.get("items")))
    except Exception as exc:
        return {
            "checkout_ok": False,
            "cart_ok": False,
            "order_id_present": False,
            "shipping_tracking_present": False,
            "shipping_address_matched": False,
            "order_items_matched": False,
            "error": f"cart: {exc}",
        }

    try:
        order = post_json(
            FRONTEND_URL,
            "/api/checkout?currencyCode=USD",
            {
                "userId": user,
                "email": "observer@example.com",
                "address": ADDRESS,
                "userCurrency": "USD",
                "creditCard": {
                    "creditCardNumber": "4432-8015-6152-0454",
                    "creditCardExpirationYear": 2039,
                    "creditCardExpirationMonth": 1,
                    "creditCardCvv": 672,
                },
            },
        )
    except Exception as exc:
        return {
            "checkout_ok": False,
            "cart_ok": cart_ok,
            "order_id_present": False,
            "shipping_tracking_present": False,
            "shipping_address_matched": False,
            "order_items_matched": False,
            "error": f"checkout: {exc}",
        }

    order_id_ok = isinstance(order.get("orderId"), str) and bool(order.get("orderId").strip())
    tracking_ok = isinstance(order.get("shippingTrackingId"), str) and bool(
        order.get("shippingTrackingId").strip()
    )
    address_ok = order.get("shippingAddress") == ADDRESS
    items = order.get("items")
    items_ok = (
        isinstance(items, list)
        and all(isinstance(it, dict) for it in items)
        and exact_items([it.get("item") for it in items])
    )
    all_ok = bool(cart_ok and order_id_ok and tracking_ok and address_ok and items_ok)
    return {
        "checkout_ok": all_ok,
        "cart_ok": cart_ok,
        "order_id_present": order_id_ok,
        "shipping_tracking_present": tracking_ok,
        "shipping_address_matched": address_ok,
        "order_items_matched": items_ok,
        "error": None if all_ok else "contract mismatch",
    }


def evaluate_live_flags():
    flags_out = {}
    for key in (
        "paymentFailure",
        "loadGeneratorTraffic",
        "loadGeneratorVUs",
        "adFailure",
        "cartFailure",
        "productCatalogFailure",
    ):
        try:
            res = post_json(
                FLAGD_URL,
                f"/ofrep/v1/evaluate/flags/{key}",
                {"context": {"product_id": "OLJCESPC7Z"}},
                timeout=5,
            )
            flags_out[key] = res.get("value")
            flags_out[f"{key}_reason"] = res.get("reason")
            flags_out[f"{key}_error"] = res.get("errorCode")
        except Exception as exc:
            flags_out[key] = None
            flags_out[f"{key}_error"] = str(exc)
    return flags_out


CACHED_LOCK = threading.Lock()
CACHED_PAYLOAD = {
    "status": "ok",
    "checkout": {
        "checkout_ok": False,
        "cart_ok": False,
        "order_id_present": False,
        "shipping_tracking_present": False,
        "shipping_address_matched": False,
        "order_items_matched": False,
        "error": "initializing",
    },
    "flags": {},
}


def status_poll_loop():
    while True:
        try:
            checkout_res = run_synthetic_checkout()
            flags_res = evaluate_live_flags()
            with CACHED_LOCK:
                CACHED_PAYLOAD["checkout"] = checkout_res
                CACHED_PAYLOAD["flags"] = flags_res
        except Exception as exc:
            log.warning("status poll error: %s", exc)
        time.sleep(10.0)


def main():
    poll_thread = threading.Thread(target=status_poll_loop, daemon=True)
    poll_thread.start()

    class StatusHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/status", "/status/"):
                self.send_response(404)
                self.end_headers()
                return
            with CACHED_LOCK:
                body = json.dumps(CACHED_PAYLOAD, sort_keys=True).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            pass

    server = ThreadingHTTPServer(("0.0.0.0", STATUS_PORT), StatusHandler)
    log.info("started storefront-status server on 0.0.0.0:%d/status", STATUS_PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
