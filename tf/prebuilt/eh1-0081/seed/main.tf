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

# seed arm: one Job running files/Audit.java in mode "seed" (see its header and the
# seed section), in kafka-audit, with only the grants listed here.
variable "audit_namespace" {
  type = string
}

variable "runner_image" {
  type = string
}

locals {
  rules = {
    streaming = [
      { apiGroups = [""], resources = ["configmaps"], resourceNames = ["streaming-changes"], verbs = ["get", "patch"] },
      { apiGroups = ["batch"], resources = ["cronjobs"], resourceNames = ["late-event-replay"], verbs = ["get"] },
    ]
    storefront = [
      { apiGroups = [""], resources = ["configmaps"], resourceNames = ["server-events", "storefront-changes"], verbs = ["get", "patch"] },
      { apiGroups = ["apps"], resources = ["deployments"], resourceNames = ["server-events"], verbs = ["get", "patch"] },
    ]
    (var.audit_namespace) = [
      { apiGroups = [""], resources = ["secrets"], resourceNames = ["seed-state", "clickstream-flags"], verbs = ["get", "patch"] },
    ]
  }
}

output "objects" {
  value = merge(
    {
      "${var.audit_namespace}/ServiceAccount/seed-runner" = {
        apiVersion = "v1", kind = "ServiceAccount"
        metadata   = { name = "seed-runner", namespace = var.audit_namespace }
      }
    },
    { for ns, r in local.rules : "${ns}/Role/clickstream-seed" => {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "Role"
      metadata   = { name = "clickstream-seed", namespace = ns }
      rules      = r
    } },
    { for ns, r in local.rules : "${ns}/RoleBinding/clickstream-seed" => {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "RoleBinding"
      metadata   = { name = "clickstream-seed", namespace = ns }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "clickstream-seed" }
      subjects   = [{ kind = "ServiceAccount", name = "seed-runner", namespace = var.audit_namespace }]
    } },
    {
      "${var.audit_namespace}/Job/clickstream-morning" = {
        apiVersion = "batch/v1", kind = "Job"
        metadata   = { name = "clickstream-morning", namespace = var.audit_namespace }
        spec = {
          backoffLimit            = 0
          ttlSecondsAfterFinished = 600
          template = {
            spec = {
              serviceAccountName = "seed-runner"
              restartPolicy      = "Never"
              containers = [{
                name         = "seed"
                image        = var.runner_image
                command      = ["sh", "-c", "cd /tmp && exec java -Xmx256m -cp '/opt/kafka/libs/*' /opt/audit/Audit.java seed"]
                resources    = { requests = { cpu = "50m", memory = "320Mi" }, limits = { memory = "448Mi" } }
                volumeMounts = [{ name = "audit", mountPath = "/opt/audit" }]
              }]
              volumes = [{ name = "audit", secret = { secretName = "audit-program" } }]
            }
          }
        }
      }
    },
  )
}

output "overrides" {
  value = {}
}
