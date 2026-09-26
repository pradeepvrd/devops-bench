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
  description = "Namespace the flagd Deployment and flagd-config ConfigMap live in"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in this module's local-exec provisioner. Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "scenario_name" {
  type        = string
  description = "Name of the scenario being applied (stack.sh's scenario argument), recorded as the living-stacks.otel-demo/scenario annotation"
  default     = "baseline"
}

variable "scenario_json" {
  type        = string
  description = "Contents of the selected scenario's flagd config JSON (caller supplies otel-demo/scenarios/<name>.json)"
}

variable "flagd_rollout_timeout" {
  type        = string
  description = "kubectl rollout status timeout for the flagd restart"
  default     = "180s"
}
