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

# Requires the benchmark's opt-in task-owned RBAC path before solver execution
# (task.yaml's agent_rbac: task); without it the harness gives the solver the
# benchmark's default grants and ignores everything this file and
# module.bench_agent's cluster_read = false declare.
#
# This task has exactly one namespace the solver ever needs to read or edit -
# the stream namespace - and module.bench_agent's own edit Role there already
# covers it (pods, pods/log, pods/exec, services, configmaps, deployments,
# jobs, plus the Strimzi CRDs from extra_rules in main.tf). What cluster_read
# used to buy on top of that, and what this file has to replace, is the
# ability to see that the stream namespace exists at all: the built-in view
# ClusterRole also read every other namespace's Deployments, Pods, pod logs,
# ConfigMaps and Jobs, which is exactly what enrichment-audit.tf's trust
# boundary depends on the solver not having (the auditor Deployment, the
# incident seed's baseline, the audit scripts and every check it runs). So
# this grants namespace discovery only, cluster-scoped and content-free, and
# nothing else cluster-wide.
locals {
  solver_subject = {
    kind = "ServiceAccount", name = "bench-agent", namespace = "bench-system"
  }
  # Discover namespaces without granting reads of their contents or other
  # cluster-scoped objects. The harness's cluster_read flag stays disabled in
  # main.tf.
  solver_namespace_discovery = {
    role = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "ClusterRole"
      metadata   = { name = "streaming-namespace-discovery" }
      rules      = [{ apiGroups = [""], resources = ["namespaces"], verbs = ["get", "list"] }]
    }
    binding = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "ClusterRoleBinding"
      metadata   = { name = "streaming-namespace-discovery" }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "ClusterRole", name = "streaming-namespace-discovery" }
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
