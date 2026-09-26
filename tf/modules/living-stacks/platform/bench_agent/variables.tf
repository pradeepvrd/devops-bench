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

variable "edit_namespaces" {
  type        = list(string)
  description = "Namespaces the bench agent gets edit-level access in: one Role plus RoleBinding per entry, granting core workload resources and secrets in that namespace only. Secrets are readable nowhere else."

  validation {
    condition     = length(var.edit_namespaces) == length(distinct(var.edit_namespaces))
    error_message = "edit_namespaces must not contain duplicates; each entry becomes one Role and one RoleBinding."
  }

  validation {
    condition     = alltrue([for ns in var.edit_namespaces : length(trimspace(ns)) > 0])
    error_message = "edit_namespaces entries must be non-empty namespace names."
  }
}

variable "cluster_read" {
  type        = bool
  description = "Bind the built-in 'view' ClusterRole to the agent cluster-wide. 'view' never includes secrets."
  default     = true
}

variable "extra_rules" {
  type = list(object({
    api_groups = list(string)
    resources  = list(string)
    verbs      = list(string)
  }))
  description = "Additional PolicyRules rendered into every per-namespace Role, never into anything cluster-scoped. Use for CRDs a task wants the solver to touch."
  default     = []

  validation {
    condition = alltrue([
      for r in var.extra_rules : !(
        (contains(r.api_groups, "rbac.authorization.k8s.io") || contains(r.api_groups, "*")) &&
        length(setintersection(toset(r.resources), toset(["clusterroles", "clusterrolebindings", "*"]))) > 0
      )
    ])
    error_message = "extra_rules must not grant access to clusterroles or clusterrolebindings, whether through the rbac.authorization.k8s.io group or a wildcard group; the agent could otherwise bind itself to cluster-admin."
  }

  validation {
    condition = alltrue([
      for r in var.extra_rules : !(
        contains(r.api_groups, "*") && contains(r.resources, "*") && contains(r.verbs, "*")
      )
    ])
    error_message = "extra_rules must not contain a wildcard-everything rule; that is cluster-admin by another name."
  }

  validation {
    condition = alltrue([
      for r in var.extra_rules : length(setintersection(toset(r.verbs), toset(["bind", "escalate", "impersonate"]))) == 0
    ])
    error_message = "extra_rules must not grant the bind, escalate, or impersonate verbs; each is a privilege-escalation path."
  }
}
