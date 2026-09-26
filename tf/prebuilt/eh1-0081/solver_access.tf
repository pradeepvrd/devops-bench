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

# Read-only RBAC the solver needs beyond module.bench_agent's edit grant on streaming and
# storefront, in the pattern of eh1-0075/eh1-0080 for a task with a protected status namespace:
# cluster_read stays false (main.tf), so there is no cluster-wide view binding, and kafka-audit
# gets no grant here.
locals {
  solver_subject = { kind = "ServiceAccount", name = "bench-agent", namespace = "bench-system" }

  solver_read = [
    { apiGroups = [""], resources = ["pods", "pods/log", "services", "endpoints", "events", "configmaps", "serviceaccounts"], verbs = ["get", "list", "watch"] },
    { apiGroups = ["apps"], resources = ["deployments", "replicasets", "statefulsets"], verbs = ["get", "list", "watch"] },
    { apiGroups = ["batch"], resources = ["jobs", "cronjobs"], verbs = ["get", "list", "watch"] },
  ]
}

resource "kubectl_manifest" "solver_namespace_discovery" {
  for_each = {
    role = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "ClusterRole"
      metadata   = { name = "clickstream-namespace-discovery" }
      rules      = [{ apiGroups = [""], resources = ["namespaces"], verbs = ["get", "list"] }]
    }
    binding = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "ClusterRoleBinding"
      metadata   = { name = "clickstream-namespace-discovery" }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "ClusterRole", name = "clickstream-namespace-discovery" }
      subjects   = [local.solver_subject]
    }
  }
  yaml_body  = yamlencode(each.value)
  depends_on = [module.bench_agent]
}

resource "kubectl_manifest" "solver_namespaced" {
  for_each = {
    operator_role = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "Role"
      metadata   = { name = "bench-agent-read", namespace = "flink-operator-streaming" }
      rules      = local.solver_read
    }
    operator_binding = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "RoleBinding"
      metadata   = { name = "bench-agent-read", namespace = "flink-operator-streaming" }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "bench-agent-read" }
      subjects   = [local.solver_subject]
    }
  }
  yaml_body  = yamlencode(each.value)
  depends_on = [module.bench_agent, module.scene_streaming]
}
