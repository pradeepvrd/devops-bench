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

# The bench reads exactly these two names out of `tofu output -json` and
# raises ConfigError if either is missing. Do not rename them.
output "cluster_name" {
  value       = module.cluster.cluster_name
  description = "The name of the created cluster"
}

output "cluster_location" {
  value       = module.cluster.cluster_location
  description = "local for kind"
}

# Non-scalar output; not a placeholder candidate. The static gate reads it from
# the plan to validate override keys against the scene registry.
output "overrides" {
  value       = local.overrides
  description = "The merged scene override map this render passes to scenes"
}
