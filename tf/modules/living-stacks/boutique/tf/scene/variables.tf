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
  description = "Namespace this instance's workload deploys into (stack.sh's NS)"
  default     = "boutique"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in ../modules/onlineboutique's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "system" {
  type        = string
  description = "Short instance label, used for living-stack=$system on the namespace and every pod (stack.sh's SYSTEM)"
  default     = "primary"
}

variable "profile" {
  type        = string
  description = "Load profile name from ../../profiles/*.json (calm, busy, rush), controls the bundled Locust loadgenerator's USERS/RATE (stack.sh's PROFILE)"
  default     = "calm"
}

variable "profile_json_path" {
  type        = string
  description = "null (default) resolves to ../../profiles/$profile.json relative to this module; a variable default cannot itself contain a path.module reference, so the real default is applied in main.tf via coalesce()."
  default     = null
}

variable "profile_json_override" {
  type        = string
  description = "Optional load profile JSON containing numeric users and rate fields. When null, profile_json_path or ../../profiles/$profile.json is read."
  default     = null

  validation {
    condition = var.profile_json_override == null ? true : (
      can(tonumber(jsondecode(var.profile_json_override).users)) &&
      can(tonumber(jsondecode(var.profile_json_override).rate))
    )
    error_message = "profile_json_override must be JSON with numeric users and rate fields."
  }
}

variable "service_endpoints" {
  type = object({
    cart_database = optional(string)
  })
  description = "Optional chart-supported service endpoints. cart_database overrides cartDatabase.connectionString without creating or patching a second owner for the Deployment."
  default     = {}
}

variable "values_path" {
  type        = string
  description = "null (default) resolves to ../../values.yaml relative to this module; see profile_json_path for why this is null here rather than a literal relative default."
  default     = null
}

variable "release_name" {
  type        = string
  description = "Passed through to ../modules/onlineboutique's release_name (chart .Release.Name templating only, not a real Helm release -- see that module's README/main.tf). null (default) resolves to boutique-$namespace, matching stack.sh's RELEASE derivation."
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

variable "rollout_timeout_seconds" {
  type        = number
  description = "Per-Deployment kubectl rollout status timeout, matching stack.sh's up_gke() (900s)"
  default     = 900
}
