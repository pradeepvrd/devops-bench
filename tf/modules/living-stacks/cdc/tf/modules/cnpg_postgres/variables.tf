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

variable "namespace" {
  type        = string
  description = "Namespace the Cluster CR and its pods deploy into (this stack's own workload namespace, i.e. stack.sh's NS)"
}

variable "system" {
  type        = string
  description = "living-stack label value for this instance (stack.sh's SYSTEM)"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in this module's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy (e.g. another process running `gcloud container clusters get-credentials` for a different cluster), pointing kubectl at the wrong cluster mid-run."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "install_operator" {
  type        = bool
  description = "Install the CloudNativePG operator via helm. Set false when a prior instance on the same cluster already installed it, matching stack.sh's own idempotent 'helm upgrade --install'."
  default     = true
}

variable "cnpg_namespace" {
  type        = string
  description = "Namespace the CloudNativePG operator installs into (cluster-wide, shared across every instance)"
  default     = "cnpg-system"
}

variable "cnpg_chart_version" {
  type        = string
  description = "cloudnative-pg helm chart version"
  default     = "0.29.0"
}

variable "instances" {
  type        = number
  description = "Number of Postgres instances (1 primary + N-1 streaming replicas)"
  default     = 2
}

variable "postgres_image" {
  type        = string
  description = "CNPG-managed Postgres image"
  default     = "ghcr.io/cloudnative-pg/postgresql:18.6"
}

variable "debezium_password_secret_name" {
  type        = string
  description = "Name of the pre-existing basic-auth Secret backing the managed 'debezium' role's password (cdc-debezium-credentials in stack.sh)"
  default     = "cdc-debezium-credentials"
}

variable "teardown_pod_absence_timeout_seconds" {
  type        = number
  description = "Seconds to poll for the Cluster's instance pods' absence after deleting the Cluster CR, on destroy. No native resource tracks CNPG's own graceful-shutdown pod teardown timing, so this bounds the hand-rolled poll (main.tf's null_resource.pod_absence_poll). Measured cold on kind, 2026-09-06: 40s; 180s is roughly 4.5x, see spec 'Verified on kind'."
  default     = 180
}
