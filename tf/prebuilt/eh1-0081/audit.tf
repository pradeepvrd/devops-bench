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

# kafka-audit: the Scene Status Exporter. files/Audit.java (mode "exporter") reads the Kafka
# topics directly and one CronJob, computes the flags described in its header, and publishes
# them into Secret kafka-audit/clickstream-flags, which task.yaml reads with native
# resource_property entries. It is never invoked through pod_exec.
#
# Isolation, all deliberate:
#   - The solver has no grant in kafka-audit (cluster_read is off; solver_access.tf binds
#     nothing here), so it cannot read the program, the pods, the seed Job or their logs.
#   - The program and every piece of state are Secrets; nothing informative is logged.
#   - Its Kafka consumers use assign() without a group id, so nothing about them appears in
#     kafka-consumer-groups.sh or on the brokers' group coordinator.
#   - A NetworkPolicy admits no ingress into kafka-audit.
#   - A liveness probe on the loop's heartbeat restarts a wedged exporter; the latched flags are
#     re-read from the flags Secret on start.
resource "kubernetes_namespace_v1" "audit" {
  metadata { name = local.audit_ns }
  depends_on = [module.cluster]
}

locals {
  audit_objects = {
    program = {
      apiVersion = "v1", kind = "Secret", type = "Opaque"
      metadata   = { name = "audit-program", namespace = local.audit_ns }
      stringData = { "Audit.java" = file("${path.module}/files/Audit.java") }
    }
    flags = {
      apiVersion = "v1", kind = "Secret", type = "Opaque"
      metadata   = { name = "clickstream-flags", namespace = local.audit_ns }
      stringData = { feed_current = "false", replay_ok = "false", data_intact = "true", no_leak = "true", published_at = "0" }
    }
    state = {
      apiVersion = "v1", kind = "Secret", type = "Opaque"
      metadata   = { name = "seed-state", namespace = local.audit_ns }
      stringData = { seeded = "false" }
    }
    sa = {
      apiVersion = "v1", kind = "ServiceAccount"
      metadata   = { name = "clickstream-audit", namespace = local.audit_ns }
    }
    audit_role = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "Role"
      metadata   = { name = "clickstream-audit", namespace = local.audit_ns }
      rules = [
        { apiGroups = [""], resources = ["secrets"], resourceNames = ["clickstream-flags", "seed-state"], verbs = ["get", "patch"] },
      ]
    }
    audit_binding = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "RoleBinding"
      metadata   = { name = "clickstream-audit", namespace = local.audit_ns }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "clickstream-audit" }
      subjects   = [{ kind = "ServiceAccount", name = "clickstream-audit", namespace = local.audit_ns }]
    }
    stream_role = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "Role"
      metadata   = { name = "clickstream-audit", namespace = local.ns }
      rules = [
        { apiGroups = ["batch"], resources = ["cronjobs"], resourceNames = ["late-event-replay"], verbs = ["get"] },
      ]
    }
    stream_binding = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "RoleBinding"
      metadata   = { name = "clickstream-audit", namespace = local.ns }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "clickstream-audit" }
      subjects   = [{ kind = "ServiceAccount", name = "clickstream-audit", namespace = local.audit_ns }]
    }
    netpol = {
      apiVersion = "networking.k8s.io/v1", kind = "NetworkPolicy"
      metadata   = { name = "no-ingress", namespace = local.audit_ns }
      spec       = { podSelector = {}, policyTypes = ["Ingress"], ingress = [] }
    }
    deployment = {
      apiVersion = "apps/v1", kind = "Deployment"
      metadata   = { name = "clickstream-status", namespace = local.audit_ns }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "clickstream-status" } }
        template = {
          metadata = { labels = { app = "clickstream-status" } }
          spec = {
            serviceAccountName = "clickstream-audit"
            containers = [{
              name    = "exporter"
              image   = var.kafka_image
              command = ["sh", "-c", "cd /tmp && exec java -Xmx448m -cp '/opt/kafka/libs/*' /opt/audit/Audit.java exporter > /dev/null 2>&1"]
              livenessProbe = {
                exec                = { command = ["sh", "-c", "test $(( $(date +%s) - $(cat /tmp/heartbeat 2>/dev/null || echo 0) )) -lt 180"] }
                initialDelaySeconds = 240
                periodSeconds       = 30
                failureThreshold    = 3
              }
              resources    = { requests = { cpu = "50m", memory = "512Mi" }, limits = { memory = "704Mi" } }
              volumeMounts = [{ name = "audit", mountPath = "/opt/audit" }]
            }]
            volumes = [{ name = "audit", secret = { secretName = "audit-program" } }]
          }
        }
      }
    }
  }
}

resource "kubectl_manifest" "audit" {
  for_each = local.audit_objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = each.key == "deployment"

  depends_on = [kubernetes_namespace_v1.audit, module.scene_streaming, kubectl_manifest.workloads]
}
