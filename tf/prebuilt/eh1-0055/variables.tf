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

# The five variables the bench's kind provider injects. An undeclared injected
# variable is dropped with a warning by the bench's tofu deployer.
variable "infra_provider" {
  type        = string
  description = "The target provider (kind)"
  default     = "kind"
}

variable "project_id" {
  type        = string
  description = "GCP project id, or local-kind"
  default     = "local-kind"
}

variable "location" {
  type        = string
  description = "Cluster location, or local"
  default     = "local"
}

variable "cluster_name" {
  type        = string
  description = "Name of the kind cluster to create; the bench sets it per run"
}

variable "kubeconfig_path" {
  type        = string
  description = "Path the kind module writes the kubeconfig to; the bench sandbox reads it"
  default     = "~/.kube/config"
}

# Stack-local variables.
variable "node_count" {
  type        = number
  description = "Nodes (1 control plane plus workers). The kind module's own default is 3."
  default     = 1
  nullable    = false
}

variable "disable_default_cni" {
  type        = bool
  description = "Disable kindnet and install Calico"
  default     = false
}

variable "arm" {
  type        = string
  description = "Which arm to render: base (seed), oracle (seed plus repair), violator (seed plus violator)"
  default     = "base"

  validation {
    condition     = contains(["base", "oracle", "violator"], var.arm)
    error_message = "arm must be one of base, oracle, violator."
  }
}
