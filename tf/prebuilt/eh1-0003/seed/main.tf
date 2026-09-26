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

# seed: the fault (S-006, P-041's injection: "the generator was configured
# so 25% of events can arrive up to an hour late, while the Flink SQL
# watermark tolerates only 30 seconds"). profile_json_override replaces the
# scene's own default profile.json (streaming/overlays/gke/profile.json at
# the pinned sha) verbatim, so every key that file declares is carried here,
# not just the two the armed check reads: the traffic_engine module takes
# profile_json_override as the whole ConfigMap content, and producer.py
# reads the full file at startup.
locals {
  overrides = {
    profile_json_override = jsonencode({
      base_rate_eps      = 15
      day_length_minutes = 120
      diurnal_amplitude  = 0.6
      burst = {
        prob_per_minute  = 0.02
        multiplier       = 4
        duration_seconds = 30
      }
      event_mix = {
        page_view        = 0.6
        add_to_cart      = 0.2
        order            = 0.1
        payment          = 0.08
        inventory_update = 0.02
      }
      zipf_alpha         = 1.2
      user_pool_size     = 5000
      product_pool_size  = 800
      malformed_fraction = 0.01
      duplicate_fraction = 0.01
      late_fraction      = 0.25
      late_max_seconds   = 3600
    })
  }
  objects = {}
}
