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

output "namespace" {
  value       = kubernetes_namespace_v1.this.metadata[0].name
  description = "This instance's owned workload namespace"
}

output "release_name" {
  value       = module.boutique.release_name
  description = "Name used for the chart's own .Release.Name templating. Not a real Helm release -- see ../modules/onlineboutique/main.tf's header comment."
}

output "applied_profile" {
  value       = var.profile
  description = "Name of the applied load profile (stack.sh's PROFILE)"
}

output "loadgen_users" {
  value       = local.profile_data.users
  description = "USERS value patched onto the loadgenerator Deployment for the applied profile"
}

output "loadgen_rate" {
  value       = local.profile_data.rate
  description = "RATE value patched onto the loadgenerator Deployment for the applied profile"
}

output "frontend_service_name" {
  value = module.boutique.frontend_service_name
}

output "loadgenerator_deployment_name" {
  value = module.boutique.loadgenerator_deployment_name
}

output "render_dir" {
  value       = module.boutique.render_dir
  description = "Directory holding the rendered chart manifest and the kustomization.yaml patching it (kubectl apply -k/-delete -k target this)"
}
