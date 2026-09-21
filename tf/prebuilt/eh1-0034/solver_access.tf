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

# Scoped read-only RBAC for bench-agent beyond orders-db edit access.
# cluster_read is false so cdc-verifier remains unreachable by solver credentials.
locals {
  solver_subject = {
    kind      = "ServiceAccount"
    name      = "bench-agent"
    namespace = "bench-system"
  }

  solver_namespace_discovery = {
    role = {
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "ClusterRole"
      metadata   = { name = "orders-namespace-discovery" }
      rules      = [{ apiGroups = [""], resources = ["namespaces"], verbs = ["get", "list"] }]
    }
    binding = {
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "ClusterRoleBinding"
      metadata   = { name = "orders-namespace-discovery" }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "ClusterRole", name = "orders-namespace-discovery" }
      subjects   = [local.solver_subject]
    }
  }
}

resource "kubectl_manifest" "solver_namespace_discovery_role" {
  yaml_body  = yamlencode(local.solver_namespace_discovery.role)
  depends_on = [module.bench_agent]
}

resource "kubectl_manifest" "solver_namespace_discovery_binding" {
  yaml_body  = yamlencode(local.solver_namespace_discovery.binding)
  depends_on = [kubectl_manifest.solver_namespace_discovery_role]
}

resource "kubectl_manifest" "solver_read_role" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "Role"
    metadata   = { name = "bench-agent-diagnostics", namespace = local.bus_namespace }
    rules = [
      { apiGroups = [""], resources = ["pods", "pods/log", "services", "endpoints", "events", "configmaps"], verbs = ["get", "list", "watch"] },
      { apiGroups = ["apps"], resources = ["deployments", "replicasets", "statefulsets"], verbs = ["get", "list", "watch"] },
      { apiGroups = ["kafka.strimzi.io"], resources = ["kafkas", "kafkatopics", "kafkanodepools", "strimzipodsets", "kafkausers"], verbs = ["get", "list", "watch"] },
    ]
  })
  depends_on = [module.bench_agent]
}

resource "kubectl_manifest" "solver_read_binding" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "RoleBinding"
    metadata   = { name = "bench-agent-diagnostics", namespace = local.bus_namespace }
    roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "bench-agent-diagnostics" }
    subjects   = [local.solver_subject]
  })
  depends_on = [kubectl_manifest.solver_read_role]
}
