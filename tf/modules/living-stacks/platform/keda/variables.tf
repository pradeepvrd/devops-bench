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

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used to connect to the Kubernetes cluster."
  default     = ""
}

variable "system" {
  type        = string
  description = "System or attempt label assigned to resources managed by this module."
  default     = "primary"
}

variable "keda_namespace" {
  type        = string
  description = "Namespace where KEDA operator and components are installed."
  default     = "keda"
}

variable "create_namespace" {
  type        = bool
  description = "Whether to create keda_namespace if it does not already exist."
  default     = true
}

variable "install_operator" {
  type        = bool
  description = "Whether to install the KEDA operator via Helm chart."
  default     = true
}

variable "install_crds" {
  type        = bool
  description = "Whether to verify and wait for KEDA CRDs to reach the Established condition."
  default     = true
}

variable "keda_chart_version" {
  type        = string
  description = "Version of the KEDA Helm chart (kedacore/keda)."
  default     = "2.16.1"
}

variable "keda_chart_repository" {
  type        = string
  description = "Helm repository URL for the KEDA chart."
  default     = "https://kedacore.github.io/charts"
}

variable "operator_replicas" {
  type        = number
  description = "Number of replicas for the KEDA operator deployment."
  default     = 1
}

variable "metrics_server_replicas" {
  type        = number
  description = "Number of replicas for the KEDA metrics server deployment."
  default     = 1
}

variable "watch_namespace" {
  type        = string
  description = "Namespace for KEDA to watch for ScaledObjects. Empty string watches all namespaces."
  default     = ""
}

variable "enable_webhooks" {
  type        = bool
  description = "Whether to enable KEDA admission webhooks."
  default     = false
}

variable "enable_prometheus_metrics" {
  type        = bool
  description = "Whether to expose Prometheus metrics from the KEDA operator."
  default     = true
}

variable "crds_ready_timeout" {
  type        = string
  description = "Timeout waiting for KEDA CRDs to reach the Established condition."
  default     = "180s"
}

variable "helm_timeout" {
  type        = number
  description = "Timeout in seconds for helm_release wait."
  default     = 300
}

variable "operator_image_repository" {
  type        = string
  description = "Image repository for KEDA operator. Can be a full repository path or mirrored OCI image."
  default     = "ghcr.io/kedacore/keda"
}

variable "operator_image_repo" {
  type        = string
  description = "Alias for operator_image_repository."
  default     = null
}

variable "operator_image_tag" {
  type        = string
  description = "Image tag for KEDA operator."
  default     = "2.16.1"
}

variable "metrics_server_image_repository" {
  type        = string
  description = "Image repository for KEDA metrics server. Can be a full repository path or mirrored OCI image."
  default     = "ghcr.io/kedacore/keda-metrics-apiserver"
}

variable "metrics_server_image_repo" {
  type        = string
  description = "Alias for metrics_server_image_repository."
  default     = null
}

variable "metrics_server_image_tag" {
  type        = string
  description = "Image tag for KEDA metrics server."
  default     = "2.16.1"
}

variable "webhooks_image_repository" {
  type        = string
  description = "Image repository for KEDA admission webhooks. Can be a full repository path or mirrored OCI image."
  default     = "ghcr.io/kedacore/keda-admission-webhooks"
}

variable "webhooks_image_repo" {
  type        = string
  description = "Alias for webhooks_image_repository."
  default     = null
}

variable "webhooks_image_tag" {
  type        = string
  description = "Image tag for KEDA admission webhooks."
  default     = "2.16.1"
}

variable "teardown_absence_timeout_seconds" {
  type        = number
  description = "Timeout in seconds for destroy-time absence poll waiting for ScaledObjects and TriggerAuthentications to be deleted."
  default     = 180
}

variable "teardown_crs_absence_timeout_seconds" {
  type        = number
  description = "Alias for teardown_absence_timeout_seconds."
  default     = null
}

variable "extra_helm_values" {
  type        = any
  description = "Additional Helm values to supply to the KEDA release."
  default     = {}
}
