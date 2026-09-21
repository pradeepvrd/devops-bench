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

# The fault, and its rollback, both performed at run time on the order enrichment
# job as the change record describes: the retention line added to that job's SQL
# and the job redeployed, two minutes of traffic, then the line removed and the job
# redeployed again, and its upgrade mode set back to savepoint.
#
# Both redeploys are fresh starts, as they have to be. Flink 1.20 refuses to restore
# state across a TTL change: adding or removing table.exec.state.ttl changes the state
# serializer, and a savepoint redeploy crash-loops on StateMigrationException
# ("the new state serializer (TtlSerializer) must not be incompatible with the old").
# Measured, not assumed: the first draft of this seed redeployed from savepoint, and
# base control 01M2SN6746VBWJ2AGV5V7BAA0T showed the order job in exactly that loop
# for 30 minutes. An operator applying or reverting this change has to drop state,
# and this seed does what they would do.
#
# The customers source reads from 'latest-offset', so every fresh start comes up with
# an empty customer dimension, and nothing refills it: customer rows are not
# re-touched in this traffic. After the rollback, every declared setting is clean,
# the record says the change was reversed, both jobs are RUNNING, and orders enrich
# against missing customers. The record names the job only by the pipeline name
# both enrichment jobs share, so "the rollback hit the other job" is the tempting
# wrong theory.
#
# Why at run time and not through the SQL override: the discovery preview is
# composed from the plan. Deploying the line declaratively and removing it at run
# time would show readers a retention line the solver's world no longer has. Done
# this way, the declared SQL is the scene's own throughout, and the plan-derived
# preview matches the live world after the rollback.
#
# The Job runs at apply time and the apply waits on it (main.tf), so it has landed
# before the attempt's clock starts, and it deletes itself a minute after completing.
# The evidence a solver can use is what a real incident leaves behind: the change
# record, the FlinkSessionJob's spec and status, the operator's events and logs, and
# the job's own behaviour.
variable "streaming_namespace" {
  type = string
}

locals {
  ns = var.streaming_namespace

  change_record = <<-TXT
    CHG-2291  Maintenance window, 02:10-02:40 UTC

    Reduced state retention on the enrichment job (pipeline primary-enrichment)
    to cap operator-side memory while the dimension backfill ran.

      SET 'table.exec.state.ttl' = '10 s';

    Reversal: remove the table.exec.state.ttl line from the enrichment job's SQL
    and redeploy that job. No other change was made.

    02:40  Rolled back per the reversal above: line removed, job redeployed,
           job RUNNING. Closed.
  TXT

  maintenance = <<-SH
    set -eu
    NS=${local.ns}
    JOB=enrichment-orders
    CM=flink-sql-scripts
    SQL_PATH=$(kubectl -n "$NS" get flinksessionjob "$JOB" -o jsonpath="{.spec.job.args[0]}")
    JM=$(kubectl -n "$NS" get pods -l component=jobmanager -o name | head -n 1)

    apply_sql() {
      kubectl -n "$NS" create configmap "$CM" --from-file="enrichment-orders.sql=$1" \
        --dry-run=client -o yaml | sed "/creationTimestamp/d" > /tmp/patch.yaml
      kubectl -n "$NS" patch configmap "$CM" --type merge --patch-file /tmp/patch.yaml
      for i in $(seq 1 60); do
        if kubectl -n "$NS" exec "$JM" -c flink-main-container -- cat "$SQL_PATH" > /tmp/mounted.sql \
          && [ "$(sha256sum < /tmp/mounted.sql)" = "$(sha256sum < "$1")" ]; then
          return 0
        fi
        sleep 5
      done
      return 1
    }

    redeploy() {
      old=$(kubectl -n "$NS" get flinksessionjob "$JOB" -o jsonpath="{.status.jobStatus.jobId}")
      kubectl -n "$NS" patch flinksessionjob "$JOB" --type merge \
        -p "{\"spec\":{\"restartNonce\":$(date +%s),\"job\":{\"upgradeMode\":\"$1\"}}}"
      for i in $(seq 1 120); do
        id=$(kubectl -n "$NS" get flinksessionjob "$JOB" -o jsonpath="{.status.jobStatus.jobId}")
        st=$(kubectl -n "$NS" get flinksessionjob "$JOB" -o jsonpath="{.status.jobStatus.state}")
        if [ -n "$id" ] && [ "$id" != "$old" ] && [ "$st" = "RUNNING" ]; then
          return 0
        fi
        sleep 5
      done
      return 1
    }

    kubectl -n "$NS" get configmap "$CM" -o jsonpath="{.data.enrichment-orders\.sql}" > /tmp/current.sql
    sed "/table\.exec\.state\.ttl/d" /tmp/current.sql > /tmp/rollback.sql
    sed "/execution\.checkpointing\.interval/a SET 'table.exec.state.ttl' = '10 s';" /tmp/rollback.sql > /tmp/change.sql
    grep -q "table.exec.state.ttl" /tmp/change.sql

    apply_sql /tmp/change.sql
    redeploy stateless
    sleep 120
    apply_sql /tmp/rollback.sql
    redeploy stateless
    kubectl -n "$NS" patch flinksessionjob "$JOB" --type merge -p "{\"spec\":{\"job\":{\"upgradeMode\":\"savepoint\"}}}"
    sleep 60
    kubectl -n "$NS" wait flinksessionjob "$JOB" --for=jsonpath='{.status.jobStatus.state}'=RUNNING --timeout=600s
  SH
}

# The change record is created by main.tf as a kubernetes_config_map_v1 rather
# than an arm object: the discovery preview reads ConfigMap payloads from those
# resource types and not from kubectl_manifest, and the record is the one piece of
# this world a reader most needs to see.
output "change_record" {
  value = local.change_record
}

output "objects" {
  value = {
    "${local.ns}/ServiceAccount/maintenance" = {
      apiVersion = "v1", kind = "ServiceAccount"
      metadata   = { name = "maintenance", namespace = local.ns }
    }
    "${local.ns}/Role/maintenance" = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "Role"
      metadata   = { name = "maintenance", namespace = local.ns }
      rules = [
        {
          apiGroups = [""]
          resources = ["configmaps"]
          verbs     = ["get", "patch"]
        },
        {
          apiGroups = [""]
          resources = ["pods"]
          verbs     = ["get", "list"]
        },
        {
          apiGroups = [""]
          resources = ["pods/exec"]
          verbs     = ["create", "get"]
        },
        {
          apiGroups = ["flink.apache.org"]
          resources = ["flinksessionjobs"]
          verbs     = ["get", "list", "watch", "patch"]
        },
      ]
    }
    "${local.ns}/RoleBinding/maintenance" = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "RoleBinding"
      metadata   = { name = "maintenance", namespace = local.ns }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "maintenance" }
      subjects   = [{ kind = "ServiceAccount", name = "maintenance", namespace = local.ns }]
    }
    "${local.ns}/Job/chg-2291" = {
      apiVersion = "batch/v1", kind = "Job"
      metadata = {
        name      = "chg-2291"
        namespace = local.ns
        labels    = { "app.kubernetes.io/component" = "change-window" }
      }
      spec = {
        backoffLimit = 6
        # Gone 30s after it completes, with its pods and logs, and main.tf holds the
        # apply until it is gone. An operator's maintenance runs from their own
        # terminal; a script left readable in the namespace is a crutch no real
        # incident offers (the first live attempt solved the task by reading and
        # reusing it).
        ttlSecondsAfterFinished = 30
        template = {
          spec = {
            serviceAccountName = "maintenance"
            restartPolicy      = "Never"
            containers = [{
              name    = "maintenance"
              image   = "bitnamilegacy/kubectl:1.29"
              command = ["bash", "-c", local.maintenance]
            }]
          }
        }
      }
    }
  }
}
