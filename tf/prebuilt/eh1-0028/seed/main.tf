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

# seed: the condition, applied under every arm.
#
# What this task is about is not a broken setting. It is a change that was
# applied, had an effect, and was then undone -- leaving the setting correct and
# the effect permanent. So the seed's job is to perform that whole sequence and
# finish it, before the solver's turn begins. By the time anyone looks:
#
#   - orders is REPLICA IDENTITY FULL, which is the correct value
#   - the enrichment consumer is wedged on a record it can never decode
#   - a known set of orders carries a status downstream has never been told about
#
# Nothing here is left half-done for the solver to walk in on, which is what
# design-hazards Hazard 1 means by cold-start seeding: there is no in-flight
# operation to interrupt and no prior revision to roll back to.
locals {
  params = jsondecode(file("${path.module}/../arms/params.json"))

  scene_namespace     = local.params.namespace
  streaming_namespace = local.params.streaming_namespace
  records_namespace   = local.params.records_namespace

  overrides = {}

  objects = {
    # The procedures an on-call would already have. It states what may not be
    # touched, and it documents the value-preserving rewrite as the sanctioned
    # way to force re-emission -- which matters, because without it a solver has
    # to guess whether writing to the source table at all is permitted, and
    # would reasonably conclude it is not (design-hazards Hazard 2: the action
    # an objective requires has to be readable somewhere).
    #
    # It does not say what is wrong here. Diagnosis is the task.
    "maintenance-records/ConfigMap/cdc-runbook" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata   = { name = "cdc-runbook", namespace = local.records_namespace }
      data       = { "runbook.md" = file("${path.module}/../records/runbook.md") }
    }

    # The change record for the window. It establishes that a bulk status change
    # happened, that it was recorded in maintenance_batch, and that the operator
    # left before the closing checks. It names no cause.
    "maintenance-records/ConfigMap/change-log" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata   = { name = "change-log", namespace = local.records_namespace }
      data       = { "CHG-4471.md" = file("${path.module}/../records/change-log.md") }
    }

    # The half-finished change itself. Runs once, at apply time, and is finished
    # long before the solver's turn starts.
    #
    # It runs in the records namespace, not beside the database, and mounts its
    # program from a Secret. That is not tidiness: the run holds edit on the
    # scene and streaming namespaces, and edit includes secrets, so a program
    # mounted there is readable whichever object carries it. The records
    # namespace is reachable by the run's cluster-wide "view" only, and view
    # never includes secrets.
    "maintenance-records/Job/orders-maintenance" = {
      apiVersion = "batch/v1"
      kind       = "Job"
      metadata   = { name = "orders-maintenance", namespace = local.records_namespace }
      spec = {
        backoffLimit = 2
        template = {
          spec = {
            restartPolicy      = "Never"
            serviceAccountName = "orders-maintenance"
            volumes = [{
              name   = "program"
              secret = { secretName = "orders-maintenance-program", defaultMode = 493 }
            }]
            containers = [{
              name         = "maintenance"
              image        = local.params.image
              command      = ["bash", "/program/maintenance.sh"]
              volumeMounts = [{ name = "program", mountPath = "/program" }]
              env = [
                { name = "PGHOST", value = "shop-rw.${local.scene_namespace}.svc" },
                { name = "PGDATABASE", value = "shop" },
                { name = "PGUSER", value = "postgres" },
                { name = "PGPASSWORD", valueFrom = { secretKeyRef = { name = "shop-admin", key = "password" } } },
                { name = "FLINK_REST", value = local.params.flink_rest },
                { name = "SETTLE_SEC", value = tostring(local.params.settle_sec) },
                { name = "BATCH_SIZE", value = tostring(local.params.batch_size) },
                { name = "MIN_BATCH", value = tostring(local.params.min_batch) },
                { name = "BATCH_STATUS", value = local.params.batch_status },
                { name = "RECORDS_NAMESPACE", value = local.records_namespace },
              ]
            }]
          }
        }
      }
    }

    # The identity the change runs as. It can delete exactly one object, the
    # Secret holding its own program, which is what it does as its last act.
    # Nothing in the cluster is hidden from a run by RBAC -- the bench binds the
    # built-in edit ClusterRole to the solver across every namespace -- so the
    # only thing that keeps the program's text away from a turn is it not being
    # there any more.
    "maintenance-records/ServiceAccount/orders-maintenance" = {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata   = { name = "orders-maintenance", namespace = local.records_namespace }
    }

    "maintenance-records/Role/orders-maintenance" = {
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "Role"
      metadata   = { name = "orders-maintenance", namespace = local.records_namespace }
      rules = [{
        apiGroups     = [""]
        resources     = ["secrets"]
        resourceNames = ["orders-maintenance-program"]
        verbs         = ["delete"]
      }]
    }

    "maintenance-records/RoleBinding/orders-maintenance" = {
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "RoleBinding"
      metadata   = { name = "orders-maintenance", namespace = local.records_namespace }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "orders-maintenance" }
      subjects   = [{ kind = "ServiceAccount", name = "orders-maintenance", namespace = local.records_namespace }]
    }

    # The identity the arm response runs as. It sits beside the database because
    # it writes to the database, and it is granted the FlinkSessionJob verbs in
    # the streaming namespace because clearing the wedged consumer is the other
    # half of the repair.
    "orders-db/ServiceAccount/pipeline-response" = {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata   = { name = "pipeline-response", namespace = local.scene_namespace }
    }

    "streaming/Role/pipeline-response" = {
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "Role"
      metadata   = { name = "pipeline-response", namespace = local.streaming_namespace }
      rules = [{
        apiGroups = ["flink.apache.org"]
        resources = ["flinksessionjobs"]
        verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
      }]
    }

    # A RoleBinding may name a subject from another namespace, which is what lets
    # the responder run next to the database and still act on the streaming
    # namespace's CRs.
    "streaming/RoleBinding/pipeline-response" = {
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "RoleBinding"
      metadata   = { name = "pipeline-response", namespace = local.streaming_namespace }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "pipeline-response" }
      subjects   = [{ kind = "ServiceAccount", name = "pipeline-response", namespace = local.scene_namespace }]
    }

    # The two objects the runs differ in. The program is mounted from here, so
    # each arm mounts only its own: the base arm observes and stops, and neither
    # the documented repair nor the shortcut is readable from inside a run the
    # solver is in.
    "orders-db/ConfigMap/pipeline-response-program" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata   = { name = "pipeline-response-program", namespace = local.scene_namespace }
      data       = { "respond.sh" = file("${path.module}/../arms/observe.sh") }
    }

    "orders-db/Job/pipeline-response" = yamldecode(templatefile(
      "${path.module}/../arms/job.yaml.tftpl", local.params
    ))
  }
}
