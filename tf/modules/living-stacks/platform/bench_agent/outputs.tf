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

output "service_account_name" {
  value       = kubernetes_service_account_v1.agent.metadata[0].name
  description = "Name of the bench agent ServiceAccount (the bench's BENCH_AGENT_SA default)"
}

output "service_account_namespace" {
  value       = kubernetes_service_account_v1.agent.metadata[0].namespace
  description = "Namespace of the bench agent ServiceAccount (the bench's BENCH_AGENT_SA_NAMESPACE default)"
}

output "edit_namespaces" {
  value       = sort(keys(kubernetes_role_v1.edit))
  description = "Namespaces that received a bench-agent-edit Role and RoleBinding"
}

output "cluster_read" {
  value       = var.cluster_read
  description = "Whether the built-in view ClusterRole is bound cluster-wide"
}
