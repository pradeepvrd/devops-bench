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

# Trusted observation, outside local.edit_namespaces. cdc-verifier carries no
# solver grant at all (main.tf's cluster_read is false and solver_access.tf
# never names this namespace), so the solver cannot list, mutate, exec into,
# or read anything here, including this Pod's own Secret.
#
# Unlike eh1-0016, none of this task's checks read a Kubernetes object: the
# fault is entirely in which tables the database's own publication lists, not
# in a Deployment's configuration or in anything a Service/ExternalName/CoreDNS
# object could stand in for, so the observer needs no Kubernetes API access at
# all -- only a Postgres credential (to read the replication slot and the
# current month's seeded order ids) and a Kafka credential (to read the feed
# topics). No ServiceAccount token with any bound RBAC is created for it.
resource "kubernetes_namespace_v1" "oracle" {
  metadata { name = local.verifier_namespace }
}

resource "kubernetes_secret_v1" "oracle" {
  metadata {
    name      = "cdc-probe-credentials"
    namespace = kubernetes_namespace_v1.oracle.metadata[0].name
  }
  data = {
    # cdc_probe's own password is the cdc-debezium-credentials value, reused
    # as a source of randomness (onboarding.sql's own comment explains why);
    # this is the same value, not a second credential.
    postgres_password = data.kubernetes_secret_v1.database_credentials.data["password"]
    kafka_password     = data.kubernetes_secret_v1.kafka_user["cdc-observer"].data["password"]
  }
}

# The checks the three verification_spec entries exec, carried in as a Secret
# rather than added to the oracle image or handed over in a ConfigMap, for the
# same two reasons eh1-0016 gives: the image's tag is a content hash over
# stack/oracle, and cdc-verifier carries no solver grant at all (main.tf's
# cluster_read is false), so this Secret is unreadable regardless of its
# kind.
resource "kubernetes_secret_v1" "oracle_checks" {
  metadata {
    name      = "cdc-observer-checks"
    namespace = kubernetes_namespace_v1.oracle.metadata[0].name
  }
  data = {
    "verify.py" = file("${path.module}/checks/verify.py")
    "server.py" = file("${path.module}/checks/server.py")
  }
}

resource "kubernetes_service_v1" "cdc_observer" {
  metadata {
    name      = "cdc-observer"
    namespace = kubernetes_namespace_v1.oracle.metadata[0].name
  }
  spec {
    selector = { app = "cdc-observer" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

resource "kubernetes_service_account_v1" "oracle" {
  metadata {
    name      = "cdc-observer"
    namespace = kubernetes_namespace_v1.oracle.metadata[0].name
  }
  automount_service_account_token = false
}

resource "kubernetes_pod_v1" "oracle" {
  metadata {
    name      = "cdc-observer"
    namespace = kubernetes_namespace_v1.oracle.metadata[0].name
    labels    = { app = "cdc-observer" }
  }
  spec {
    service_account_name            = kubernetes_service_account_v1.oracle.metadata[0].name
    automount_service_account_token = false
    restart_policy                  = "Always"

    # Waits for the actual debezium replication slot to become active. Ordered
    # behind connector_rollout so the slot it waits for is the connector's
    # real, final one (onboarding.sql drops whatever the scene's brief default
    # run created before this task's own configuration ever takes effect).
    init_container {
      name              = "wait-for-replication-slot"
      image             = var.oracle_image
      image_pull_policy = "IfNotPresent"
      command           = ["python", "/oracle/startup.py"]
      env {
        name  = "PGHOST"
        value = "shop-rw.${local.source_namespace}.svc"
      }
      env {
        name = "PGPASSWORD"
        value_from {
          secret_key_ref {
            name = kubernetes_secret_v1.oracle.metadata[0].name
            key  = "postgres_password"
          }
        }
      }
      env {
        name  = "KAFKA_BOOTSTRAP"
        value = module.cdc_bus.kafka_bootstrap
      }
      env {
        name = "KAFKA_PASSWORD"
        value_from {
          secret_key_ref {
            name = kubernetes_secret_v1.oracle.metadata[0].name
            key  = "kafka_password"
          }
        }
      }
      volume_mount {
        name       = "state"
        mount_path = "/state"
      }
      resources {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
      security_context {
        read_only_root_filesystem  = true
        allow_privilege_escalation = false
      }
    }

    # The baseline both holds and the converge objective read against: the
    # slot's identity and position, the partition/offset extent of every topic
    # the ticket says to preserve, the set of order ids already delivered on
    # cdc.public.orders before this instant, and the set of order ids the
    # current month's partition already held. Recorded once, to /state (an
    # emptyDir, so this reruns if the Pod itself is replaced; verify.py's own
    # writer is first-writer-wins), before this Pod is Ready and therefore
    # before the agent's turn begins and before the violator arm's own reset
    # sequence (main.tf orders that behind this Pod becoming Ready).
    #
    # Waits for the connector to quiesce before recording anything
    # (core.wait_for_quiescence(), checks/verify.py's record_baseline()): up
    # to 180s, plus the slot/topic/delivered-id scans that follow it
    # (checks/verify.py's own BASELINE_BUDGET_SEC=210s covers both). This
    # container used to complete almost immediately once the replication slot
    # came up -- before Debezium's initial snapshot of the scene's other
    # tables had finished producing to Kafka -- and the trailing snapshot 'r'
    # events that arrived afterward tripped the history hold as if a
    # resnapshot had happened.
    init_container {
      name              = "record-baseline"
      image             = var.oracle_image
      image_pull_policy = "IfNotPresent"
      command           = ["python", "/checks/verify.py", "baseline"]
      env {
        name  = "PGHOST"
        value = "shop-rw.${local.source_namespace}.svc"
      }
      env {
        name = "PGPASSWORD"
        value_from {
          secret_key_ref {
            name = kubernetes_secret_v1.oracle.metadata[0].name
            key  = "postgres_password"
          }
        }
      }
      env {
        name  = "KAFKA_BOOTSTRAP"
        value = module.cdc_bus.kafka_bootstrap
      }
      env {
        name = "KAFKA_PASSWORD"
        value_from {
          secret_key_ref {
            name = kubernetes_secret_v1.oracle.metadata[0].name
            key  = "kafka_password"
          }
        }
      }
      volume_mount {
        name       = "state"
        mount_path = "/state"
      }
      volume_mount {
        name       = "checks"
        mount_path = "/checks"
        read_only  = true
      }
      resources {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
      security_context {
        read_only_root_filesystem  = true
        allow_privilege_escalation = false
      }
    }

    container {
      name              = "oracle"
      image             = var.oracle_image
      image_pull_policy = "IfNotPresent"
      command           = ["python", "/checks/server.py"]
      port {
        name           = "http"
        container_port = 8080
      }
      env {
        name  = "PGHOST"
        value = "shop-rw.${local.source_namespace}.svc"
      }
      env {
        name = "PGPASSWORD"
        value_from {
          secret_key_ref {
            name = kubernetes_secret_v1.oracle.metadata[0].name
            key  = "postgres_password"
          }
        }
      }
      env {
        name  = "KAFKA_BOOTSTRAP"
        value = module.cdc_bus.kafka_bootstrap
      }
      env {
        name = "KAFKA_PASSWORD"
        value_from {
          secret_key_ref {
            name = kubernetes_secret_v1.oracle.metadata[0].name
            key  = "kafka_password"
          }
        }
      }
      # Not read_only: this container is the monitor, and the heartbeat and
      # the latched baselines/violations are all written here.
      volume_mount {
        name       = "state"
        mount_path = "/state"
      }
      volume_mount {
        name       = "checks"
        mount_path = "/checks"
        read_only  = true
      }
      readiness_probe {
        exec { command = ["python", "-c", "from pathlib import Path; import time; p=Path('/state/heartbeat'); assert p.exists() and time.time()-float(p.read_text()) < 10"] }
        initial_delay_seconds = 3
        period_seconds        = 5
      }
      resources {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
      security_context {
        read_only_root_filesystem  = true
        allow_privilege_escalation = false
      }
    }

    volume {
      name = "state"
      empty_dir {}
    }

    volume {
      name = "checks"
      secret {
        secret_name  = kubernetes_secret_v1.oracle_checks.metadata[0].name
        default_mode = "0444"
      }
    }
  }
  # 6m covered wait-for-replication-slot (up to ~60s) plus the old, near-
  # instant record-baseline. record-baseline can now wait up to 180s for the
  # connector to quiesce before its own 210s budget is exhausted, so this
  # needs more headroom to still apply cleanly.
  timeouts { create = "10m" }
  depends_on = [kubectl_manifest.connector_rollout]
}

# The source-namespace edit grant must not permit privileged/hostPath escape
# into the node hosting the protected verifier Pod.
resource "kubernetes_labels" "solver_pod_security" {
  api_version = "v1"
  kind        = "Namespace"
  metadata { name = local.source_namespace }
  labels = {
    "pod-security.kubernetes.io/enforce"         = "baseline"
    "pod-security.kubernetes.io/enforce-version" = "latest"
  }
  depends_on = [module.scene_cdc]
}
