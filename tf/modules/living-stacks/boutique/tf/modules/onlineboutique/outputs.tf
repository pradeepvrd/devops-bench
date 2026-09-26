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

output "release_name" {
  value       = local.release_name
  description = "Name used for the chart's own .Release.Name templating. Not a real Helm release name -- see main.tf's header comment."
}

output "frontend_service_name" {
  value       = "frontend"
  description = "In-cluster Service name the chart creates for the frontend (fixed by the chart, not user-configurable)"
}

output "loadgenerator_deployment_name" {
  value       = local.loadgen_name
  description = "Name of the loadgenerator Deployment the kustomize patch sets USERS/RATE on"
}

output "render_dir" {
  value       = local.render_dir
  description = "Directory holding the rendered chart manifest and the kustomization.yaml that patches it; kubectl apply -k/-delete -k target this directory"
}
