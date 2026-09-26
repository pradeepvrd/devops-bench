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

output "keda_namespace" {
  value       = var.keda_namespace
  description = "Namespace where KEDA is deployed."
}

output "operator_installed" {
  value       = var.install_operator
  description = "Whether the KEDA operator Helm release was installed."
}

output "chart_version" {
  value       = var.keda_chart_version
  description = "Version of the KEDA Helm chart installed."
}

output "watch_namespace" {
  value       = var.watch_namespace
  description = "Namespace watched by KEDA operator (empty means all namespaces)."
}

output "keda_crds" {
  value       = local.crds
  description = "List of KEDA CRDs supported and waited for by this module."
}

output "service_account_name" {
  value       = var.install_operator ? "keda-operator" : ""
  description = "ServiceAccount used by the KEDA operator."
}

output "operator_image" {
  value       = "${local.operator_image_repo}:${var.operator_image_tag}"
  description = "Container image reference used for KEDA operator."
}

output "metrics_server_image" {
  value       = "${local.metrics_server_image_repo}:${var.metrics_server_image_tag}"
  description = "Container image reference used for KEDA metrics server."
}
