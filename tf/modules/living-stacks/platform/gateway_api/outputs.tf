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

output "gateway_namespace" {
  value       = var.gateway_namespace
  description = "Namespace of the shared Gateway and controller fixture."
}

output "gateway_name" {
  value       = var.gateway_name
  description = "Name of the shared Gateway object."
}

output "gateway_class_name" {
  value       = var.gateway_class_name
  description = "Name of the GatewayClass object."
}

output "gateway_port" {
  value       = var.gateway_port
  description = "Port exposed on the shared Gateway HTTP listener."
}

output "gateway_service_name" {
  value       = var.install_controller_fixture ? kubernetes_service_v1.shared_gateway[0].metadata[0].name : var.gateway_name
  description = "Name of the Kubernetes Service exposing the shared Gateway fixture."
}

output "standard_crds" {
  value       = local.standard_crds
  description = "List of standard Gateway API CRDs managed by this module."
}

output "crds_installed" {
  value       = var.install_crds
  description = "Whether Gateway API standard CRDs were installed by this module."
}

output "crds_manifest_source" {
  value       = local.crds_manifest_source
  description = "Manifest source used for Gateway API standard CRDs."
}

output "gateway_listeners" {
  value       = local.gateway_listeners
  description = "Configured listeners on the shared Gateway."
}
