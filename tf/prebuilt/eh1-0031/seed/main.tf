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

# seed: the fault, as scene overrides and objects. Applied under every arm.
#
# Stays empty for this task: the fault is the as-onboarded database state
# itself (onboarding.sql's publication membership, which the current month's
# partition was never added to), applied once at the root module and common
# to every arm, not an arm-conditional object or override. See
# stack/README.md.
locals {
  overrides = {}
  objects   = {}
}
