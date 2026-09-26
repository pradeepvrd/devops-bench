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

# Reuses the scene's own generated cdc-debezium-credentials Secret as a
# source of randomness for cdc_probe's password, the same reuse eh1-0016
# makes, instead of provisioning a separate random_password resource.
data "kubernetes_secret_v1" "database_credentials" {
  metadata {
    name      = "cdc-debezium-credentials"
    namespace = local.source_namespace
  }
  depends_on = [module.scene_cdc]
}

# shop-superuser is a CNPG-managed Secret and only ever exists in
# orders-db. The onboarding and repair Jobs below run in cdc-verifier
# instead (see the Secret-vs-ConfigMap comment further down), and a
# secretKeyRef can only resolve a Secret in the Pod's own namespace, so the
# password is copied across the namespace boundary the same way oracle.tf
# already copies cdc-debezium-credentials into cdc-probe-credentials.
data "kubernetes_secret_v1" "postgres_superuser" {
  metadata {
    name      = "shop-superuser"
    namespace = local.source_namespace
  }
  depends_on = [module.scene_cdc]
}

# One Secret, in cdc-verifier, carrying both credentials the onboarding Job
# needs (the superuser password to run onboarding.sql, and the debezium
# credential reused as cdc_probe's password) plus the superuser password the
# repair module also needs (main.tf passes this Secret's name into
# module.repair as postgres_superuser_secret). Never readable from
# orders-db's edit grant, so a solver with edit access there gains nothing
# from it the way it could from a same-namespace copy.
resource "kubernetes_secret_v1" "verifier_credentials" {
  metadata {
    name      = "orders-release-0031-credentials"
    namespace = kubernetes_namespace_v1.oracle.metadata[0].name
  }
  data = {
    password       = data.kubernetes_secret_v1.postgres_superuser.data["password"]
    probe_password = data.kubernetes_secret_v1.database_credentials.data["password"]
  }
}

# onboarding.sql's publication step only ever adds the previous month's
# orders partition, never the current one: that gap is this task's own
# fault, deliberately left for the solver to find and fix (see story.yaml's
# true_cause). Its content ships verbatim into this Secret (not a ConfigMap):
# the static gate's plan preview -- what a tableread reader actually sees --
# renders kubernetes_secret_v1's data as "(sensitive value)", where a
# ConfigMap's data renders in cleartext, so the CREATE-PUBLICATION-adjacent
# ALTER PUBLICATION statement and its explicit table list never show up in
# declared state. The onboarding Job's own log stays neutral for the same
# reason: no `-e`/`-a` psql echo of the statements it ran. This Secret also
# now lives in cdc-verifier rather than orders-db: orders-db is a solver
# edit namespace, so bench_agent's Role there grants get on every Secret in
# it, and a live solver running `kubectl get secret cdc-onboarding-bootstrap
# -o yaml` would still read the publication statement and its explicit
# table list straight out of declared state even though the tableread
# preview never shows it. cdc-verifier carries no solver grant at all
# (solver_access.tf's read Role covers only cdc-bus; cluster_read is false)
# and is never in edit_namespaces, so this closes that gap rather than only
# the preview-time one.
resource "kubernetes_secret_v1" "onboarding" {
  metadata {
    name      = "cdc-onboarding-bootstrap"
    namespace = kubernetes_namespace_v1.oracle.metadata[0].name
  }
  data       = { "onboarding.sql" = file("${path.module}/onboarding.sql") }
  depends_on = [module.scene_cdc]
}

# Schema migration, publication membership and seed data. Runs once, as the
# postgres superuser, as soon as the CNPG cluster answers -- not gated on the
# debezium replication slot being active the way eh1-0016's onboarding waits,
# because this task's own onboarding.sql is what first establishes the slot
# this task actually wants (it drops whatever the scene's brief default run
# already created; see onboarding.sql's own header). Runs in cdc-verifier
# (see the Secret above), reaching the CNPG primary across the namespace
# boundary at shop-rw.orders-db.svc, the same cross-namespace Service
# address oracle.tf's own Pod already uses.
resource "kubernetes_job_v1" "onboarding" {
  metadata {
    name      = "orders-release-0031"
    namespace = kubernetes_namespace_v1.oracle.metadata[0].name
  }
  spec {
    backoff_limit           = 0
    active_deadline_seconds = 300
    template {
      metadata {}
      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        container {
          name  = "onboard"
          image = "ghcr.io/cloudnative-pg/postgresql:18.6"
          command = ["sh", "-c", <<-EOT
            set -eu
            export PGCONNECT_TIMEOUT=4
            ready=false
            for n in $(seq 1 50); do
              if pg_isready -q -h "shop-rw.${local.source_namespace}.svc" -p 5432; then ready=true; break; fi
              sleep 3
            done
            test "$ready" = true
            psql -v probe_password="$PROBE_PASSWORD" -f /bootstrap/onboarding.sql
            stmt_count=$(grep -c ';' /bootstrap/onboarding.sql)
            echo "onboarding: applied $stmt_count statements"
          EOT
          ]
          env {
            name  = "PGHOST"
            value = "shop-rw.${local.source_namespace}.svc"
          }
          env {
            name  = "PGDATABASE"
            value = "shop"
          }
          env {
            name  = "PGUSER"
            value = "postgres"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.verifier_credentials.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name = "PROBE_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.verifier_credentials.metadata[0].name
                key  = "probe_password"
              }
            }
          }
          volume_mount {
            name       = "bootstrap"
            mount_path = "/bootstrap"
            read_only  = true
          }
        }
        volume {
          name = "bootstrap"
          secret { secret_name = kubernetes_secret_v1.onboarding.metadata[0].name }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "6m" }
  depends_on = [module.scene_cdc]
}

# The plausible "partition maintenance" artefact the ticket's "the monthly
# platform maintenance ran on the 1st" line refers to: a script that creates a
# future month's orders partition ahead of time, run both as a one-shot Job
# (representing the run that already happened this month) and as a suspended
# monthly CronJob (representing the mechanism that keeps doing it). Neither
# object ever touches cdc_publication -- creating a partition and publishing
# it are two different operations, and this script only ever does the first
# one. That gap is the fault; this script is not it.
resource "kubernetes_config_map_v1" "partition_maintenance" {
  metadata {
    name      = "orders-partition-maintenance-script"
    namespace = local.source_namespace
  }
  data = {
    "create-partition.sh" = <<-EOT
      set -eu
      export PGCONNECT_TIMEOUT=4
      name=$(psql -tAc "SELECT 'orders_' || to_char(date_trunc('month', now() + make_interval(months => $OFFSET_MONTHS)), 'YYYY_MM')")
      start=$(psql -tAc "SELECT date_trunc('month', now() + make_interval(months => $OFFSET_MONTHS))")
      stop=$(psql -tAc "SELECT date_trunc('month', now() + make_interval(months => ($OFFSET_MONTHS + 1)))")
      exists=$(psql -tAc "SELECT EXISTS (SELECT 1 FROM pg_class WHERE relname = '$name')")
      if [ "$exists" != "t" ]; then
        psql -v ON_ERROR_STOP=1 -c "CREATE TABLE public.$name PARTITION OF public.orders FOR VALUES FROM ('$start') TO ('$stop')"
        psql -v ON_ERROR_STOP=1 -c "ALTER TABLE public.$name REPLICA IDENTITY FULL"
        echo "orders-partition-maintenance: created partition $name ($start to $stop)"
      else
        echo "orders-partition-maintenance: partition $name already exists"
      fi
      echo "orders-partition-maintenance: done"
    EOT
  }
  depends_on = [module.scene_cdc]
}

# The run "the monthly platform maintenance ran on the 1st" already made:
# OFFSET_MONTHS=0 creates (or confirms) the current month's partition. Runs
# after onboarding.sql, which already created this partition as part of the
# schema migration; the idempotent existence check here means this Job's own
# log is what an operator actually finds when they look, without racing or
# duplicating onboarding.sql's own DDL.
resource "kubernetes_job_v1" "partition_maintenance_bootstrap" {
  metadata {
    name      = "orders-partition-maintenance-20260901"
    namespace = local.source_namespace
    labels    = { "app.kubernetes.io/component" = "orders-partition-maintenance" }
  }
  spec {
    backoff_limit           = 0
    active_deadline_seconds = 120
    template {
      metadata {}
      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        container {
          name    = "create-partition"
          image   = "ghcr.io/cloudnative-pg/postgresql:18.6"
          command = ["sh", "/scripts/create-partition.sh"]
          env {
            name  = "PGHOST"
            value = "shop-rw"
          }
          env {
            name  = "PGDATABASE"
            value = "shop"
          }
          env {
            name  = "PGUSER"
            value = "postgres"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "shop-superuser"
                key  = "password"
              }
            }
          }
          env {
            name  = "OFFSET_MONTHS"
            value = "0"
          }
          volume_mount {
            name       = "script"
            mount_path = "/scripts"
            read_only  = true
          }
        }
        volume {
          name = "script"
          config_map {
            name         = kubernetes_config_map_v1.partition_maintenance.metadata[0].name
            default_mode = "0555"
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "3m" }
  # Behind onboarding.sql (which already created this partition), purely so
  # this Job's idempotent check has something to find rather than a race with
  # the migration that replaces the orders table out from under it.
  depends_on = [kubernetes_job_v1.onboarding]
}

# The mechanism, kept running (suspended) rather than removed: a solver who
# reads it sees a CronJob that creates next month's partition on schedule and
# never touches the publication, which is the true cause stated as a running
# object instead of only as prose. Suspended so it never fires during a turn;
# 00:00 on the 28th is a plausible "provision a few days early" schedule.
resource "kubernetes_cron_job_v1" "partition_maintenance" {
  metadata {
    name      = "orders-partition-maintenance"
    namespace = local.source_namespace
  }
  spec {
    schedule                      = "0 0 28 * *"
    suspend                       = true
    concurrency_policy             = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        active_deadline_seconds = 120
        template {
          metadata {}
          spec {
            restart_policy                  = "Never"
            automount_service_account_token = false
            container {
              name    = "create-partition"
              image   = "ghcr.io/cloudnative-pg/postgresql:18.6"
              command = ["sh", "/scripts/create-partition.sh"]
              env {
                name  = "PGHOST"
                value = "shop-rw"
              }
              env {
                name  = "PGDATABASE"
                value = "shop"
              }
              env {
                name  = "PGUSER"
                value = "postgres"
              }
              env {
                name = "PGPASSWORD"
                value_from {
                  secret_key_ref {
                    name = "shop-superuser"
                    key  = "password"
                  }
                }
              }
              env {
                name  = "OFFSET_MONTHS"
                value = "1"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
            }
            volume {
              name = "script"
              config_map {
                name         = kubernetes_config_map_v1.partition_maintenance.metadata[0].name
                default_mode = "0555"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [module.scene_cdc]
}
