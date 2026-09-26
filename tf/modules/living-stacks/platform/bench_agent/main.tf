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

# Creates the ServiceAccount the bench's sandbox mints its token for
# (devops_bench/agents/sandbox.py: BENCH_AGENT_SA defaults to "bench-agent",
# BENCH_AGENT_SA_NAMESPACE defaults to "bench-system") and the RBAC around it.
#
# Grant shape:
#   - cluster_read: one ClusterRoleBinding to the built-in "view" ClusterRole.
#   - edit_namespaces: one Role + RoleBinding per namespace. The Role grants
#     edit verbs on core workload resources plus secrets, then extra_rules.
# Nothing here can reference cluster-admin: the only ClusterRole name that
# appears is the literal "view", and the variable validations refuse
# extra_rules that could reach clusterroles or clusterrolebindings.
#
# The namespaces in edit_namespaces must exist before this module applies. A
# stack root sources this module with depends_on on the scene modules and the
# arm objects that create those namespaces.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.0"
    }
  }
}

locals {
  namespace            = "bench-system"
  service_account_name = "bench-agent"
  view_cluster_role    = "view"

  labels = {
    "app.kubernetes.io/name"       = "bench-agent"
    "app.kubernetes.io/managed-by" = "living-stacks"
    "living-stack-component"       = "bench-agent"
  }

  edit_verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]

  base_rules = [
    {
      api_groups = [""]
      resources  = ["pods", "pods/log", "pods/status", "services", "endpoints", "configmaps", "secrets", "serviceaccounts", "persistentvolumeclaims", "events", "resourcequotas", "limitranges"]
      verbs      = local.edit_verbs
    },
    {
      api_groups = [""]
      resources  = ["pods/exec", "pods/portforward"]
      verbs      = ["create", "get"]
    },
    {
      api_groups = ["apps"]
      resources  = ["deployments", "deployments/scale", "replicasets", "statefulsets", "statefulsets/scale", "daemonsets"]
      verbs      = local.edit_verbs
    },
    {
      api_groups = ["batch"]
      resources  = ["jobs", "cronjobs"]
      verbs      = local.edit_verbs
    },
    {
      api_groups = ["autoscaling"]
      resources  = ["horizontalpodautoscalers"]
      verbs      = local.edit_verbs
    },
    {
      api_groups = ["policy"]
      resources  = ["poddisruptionbudgets"]
      verbs      = local.edit_verbs
    },
    {
      api_groups = ["networking.k8s.io"]
      resources  = ["networkpolicies", "ingresses"]
      verbs      = local.edit_verbs
    },
  ]

  role_rules = concat(local.base_rules, var.extra_rules)
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = local.namespace
    labels = local.labels
  }
}

resource "kubernetes_service_account_v1" "agent" {
  metadata {
    name      = local.service_account_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role_binding_v1" "view" {
  count = var.cluster_read ? 1 : 0

  metadata {
    name   = "bench-agent-view"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = local.view_cluster_role
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.agent.metadata[0].name
    namespace = kubernetes_service_account_v1.agent.metadata[0].namespace
  }
}

resource "kubernetes_role_v1" "edit" {
  for_each = toset(var.edit_namespaces)

  metadata {
    name      = "bench-agent-edit"
    namespace = each.value
    labels    = local.labels
  }

  dynamic "rule" {
    for_each = local.role_rules
    content {
      api_groups = rule.value.api_groups
      resources  = rule.value.resources
      verbs      = rule.value.verbs
    }
  }
}

resource "kubernetes_role_binding_v1" "edit" {
  for_each = toset(var.edit_namespaces)

  metadata {
    name      = "bench-agent-edit"
    namespace = each.value
    labels    = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.edit[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.agent.metadata[0].name
    namespace = kubernetes_service_account_v1.agent.metadata[0].namespace
  }
}
