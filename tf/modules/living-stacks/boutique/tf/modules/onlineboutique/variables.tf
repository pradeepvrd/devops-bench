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
  description = "Namespace this release renders into and applies against (stack.sh's NS); created by the caller (../../scene)"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in this module's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy (e.g. another process running `gcloud container clusters get-credentials` for a different cluster), pointing kubectl at the wrong cluster mid-run."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "system" {
  type        = string
  description = "Short instance label, patched onto every pod template as living-stack=$system (stack.sh's SYSTEM)"
  default     = "primary"
}

variable "release_name" {
  type        = string
  description = "Name used for the chart's own .Release.Name templating. null (default) resolves to boutique-$namespace, matching stack.sh's RELEASE derivation exactly. No real Helm release is created either way -- see main.tf's header comment."
  default     = null
}

variable "chart_repository" {
  type    = string
  default = "oci://us-docker.pkg.dev/online-boutique-ci/charts"
}

variable "chart_name" {
  type    = string
  default = "onlineboutique"
}

variable "chart_version" {
  type    = string
  default = "0.10.6"
}

variable "values_path" {
  type        = string
  description = "Path to the chart values file (boutique/values.yaml). No default here since a variable default cannot itself contain a path.module reference; the real default is applied by ../../scene/main.tf via coalesce()."
  default     = null
}

variable "cart_database_endpoint" {
  type        = string
  description = "Optional cartDatabase.connectionString value layered through the chart's supported values surface."
  default     = null
}

variable "loadgen_users" {
  type        = number
  description = "USERS value patched onto the loadgenerator Deployment's main container env (stack.sh's PROFILE-derived LOADGEN_USERS)"
}

variable "loadgen_rate" {
  type        = number
  description = "RATE value patched onto the loadgenerator Deployment's main container env (stack.sh's PROFILE-derived LOADGEN_RATE)"
}

variable "rollout_timeout_seconds" {
  type        = number
  description = "Per-Deployment kubectl rollout status timeout, matching stack.sh's up_gke() (900s)"
  default     = 900
}
