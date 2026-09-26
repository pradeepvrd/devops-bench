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

output "cluster_name" {
  value       = local.cluster_name
  description = "Name of the CNPG Cluster CR (fixed at 'shop', matching stack.sh's CLUSTER_NAME)"
}

output "primary_service" {
  value       = "${local.cluster_name}-rw"
  description = "Read-write service DNS name for the primary instance"
}

output "superuser_secret_name" {
  value       = "${local.cluster_name}-superuser"
  description = "CNPG-generated Secret holding the postgres superuser credentials"
}

output "app_secret_name" {
  value       = "${local.cluster_name}-app"
  description = "CNPG-generated Secret holding the initdb 'app' owner credentials"
}

output "cnpg_namespace" {
  value       = var.cnpg_namespace
  description = "Namespace the CloudNativePG operator is installed into"
}
