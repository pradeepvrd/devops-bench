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

try:
    with open("/profile/profile.json") as f:
        p = json.load(f)
    keys = {
        "base_rate_eps",
        "day_length_minutes",
        "diurnal_amplitude",
        "burst",
        "event_mix",
        "zipf_alpha",
        "user_pool_size",
        "product_pool_size",
        "malformed_fraction",
        "duplicate_fraction",
        "late_fraction",
        "late_max_seconds",
    }
    ok = (
        isinstance(p, dict)
        and keys <= p.keys()
        and type(p["late_fraction"]) in (int, float)
        and p["late_fraction"] == 0
        and type(p["late_max_seconds"]) in (int, float)
        and p["late_max_seconds"] == 1
        and type(p["base_rate_eps"]) in (int, float)
        and p["base_rate_eps"] > 0
        and isinstance(p["event_mix"], dict)
        and p["event_mix"].get("order", 0) > 0
        and isinstance(p["burst"], dict)
        and {"prob_per_minute", "multiplier", "duration_seconds"} <= p["burst"].keys()
    )
except (KeyError, ValueError, TypeError, OSError):
    ok = False
print("pass" if ok else "fail")
