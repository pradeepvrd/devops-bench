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

data "kubernetes_secret_v1" "database_credentials" {
  metadata {
    name      = "cdc-debezium-credentials"
    namespace = local.source_namespace
  }
  depends_on = [module.scene_cdc]
}

data "kubernetes_secret_v1" "postgres_superuser" {
  metadata {
    name      = "shop-superuser"
    namespace = local.source_namespace
  }
  depends_on = [module.scene_cdc]
}

resource "kubernetes_namespace_v1" "verifier" {
  metadata { name = local.verifier_namespace }
}

resource "kubernetes_service_account_v1" "repair" {
  metadata {
    name      = "cdc-operator"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  automount_service_account_token = true
}

resource "kubernetes_role_v1" "repair_orders_db" {
  metadata {
    name      = "cdc-operator-orders-access"
    namespace = local.source_namespace
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "services", "endpoints", "configmaps"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "deployments/scale"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  rule {
    api_groups = ["postgresql.cnpg.io"]
    resources  = ["clusters", "clusters/status"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  depends_on = [module.scene_cdc]
}

resource "kubernetes_role_binding_v1" "repair_orders_db" {
  metadata {
    name      = "cdc-operator-orders-access"
    namespace = local.source_namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.repair_orders_db.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.repair.metadata[0].name
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
}

resource "kubernetes_labels" "solver_pod_security" {
  api_version = "v1"
  kind        = "Namespace"
  metadata {
    name = local.source_namespace
  }
  labels = {
    "pod-security.kubernetes.io/enforce"         = "baseline"
    "pod-security.kubernetes.io/enforce-version" = "latest"
  }
  depends_on = [module.scene_cdc]
}

resource "kubernetes_secret_v1" "verifier_credentials" {
  metadata {
    name      = "orders-release-0076-credentials"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  data = {
    password       = data.kubernetes_secret_v1.postgres_superuser.data["password"]
    probe_password = data.kubernetes_secret_v1.database_credentials.data["password"]
  }
}

resource "kubernetes_secret_v1" "onboarding" {
  metadata {
    name      = "cdc-onboarding-bootstrap"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  data       = { "onboarding.sql" = file("${path.module}/onboarding.sql") }
  depends_on = [module.scene_cdc]
}

resource "kubernetes_job_v1" "onboarding" {
  metadata {
    name      = "orders-onboard-0076"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  spec {
    backoff_limit = 6
    template {
      metadata { name = "orders-onboard-0076" }
      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        container {
          name              = "psql"
          image             = "ghcr.io/cloudnative-pg/postgresql:18.6"
          image_pull_policy = "IfNotPresent"
          command = [
            "bash", "-ec",
            "until pg_isready -h shop-rw.${local.source_namespace}.svc -U postgres -d shop; do sleep 2; done; psql -h shop-rw.${local.source_namespace}.svc -U postgres -d shop -v probe_password=\"$PROBE_PASSWORD\" -f /sql/onboarding.sql"
          ]
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
            name       = "sql"
            mount_path = "/sql"
            read_only  = true
          }
        }
        volume {
          name = "sql"
          secret {
            secret_name = kubernetes_secret_v1.onboarding.metadata[0].name
          }
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "5m"
  }
  depends_on = [
    module.scene_cdc,
    kubectl_manifest.connector_quiesce,
    kubernetes_secret_v1.verifier_credentials,
    kubernetes_secret_v1.onboarding,
    # the two-phase restart has to finish first, or it lands in the middle of onboarding
    kubernetes_job_v1.wait_twophase,
  ]
}
