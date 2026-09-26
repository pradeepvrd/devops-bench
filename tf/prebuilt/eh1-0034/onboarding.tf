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
    name      = "orders-release-0034-credentials"
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
    name      = "orders-onboard-0034"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  spec {
    backoff_limit = 6
    template {
      metadata { name = "orders-onboard-0034" }
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
  ]
}

resource "kubernetes_config_map_v1" "audit_state" {
  metadata {
    name      = "cdc-audit-state"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  data = {
    phase  = "pending"
    valid  = "true"
    active = "false"
    ready  = "false"
  }
}

resource "kubernetes_role_v1" "verifier_state_access" {
  metadata {
    name      = "cdc-verifier-state-access"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = [kubernetes_config_map_v1.audit_state.metadata[0].name]
    verbs          = ["get", "update", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "verifier_state_access" {
  metadata {
    name      = "cdc-verifier-state-access"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.verifier_state_access.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.repair.metadata[0].name
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
}

resource "kubernetes_secret_v1" "auditor_script" {
  metadata {
    name      = "cdc-verifier-auditor-script"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  data = {
    "run.py" = <<-EOT
      import json
      import os
      import ssl
      import time
      import urllib.request
      import psycopg

      SOURCE_NS = os.environ["SOURCE_NAMESPACE"]
      VERIFIER_NS = os.environ["VERIFIER_NAMESPACE"]
      PGPASSWORD = os.environ["PGPASSWORD"]

      SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
      with open(f"{SA_DIR}/token", "r", encoding="utf-8") as fh:
          TOKEN = fh.read().strip()
      SSL_CTX = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
      API_ROOT = "https://kubernetes.default.svc"

      def k8s_req(method, path, body=None, content_type="application/json"):
          data = json.dumps(body).encode("utf-8") if body is not None else None
          req = urllib.request.Request(
              f"{API_ROOT}{path}",
              data=data,
              method=method,
              headers={
                  "Authorization": f"Bearer {TOKEN}",
                  "Accept": "application/json",
                  "Content-Type": content_type,
              },
          )
          with urllib.request.urlopen(req, context=SSL_CTX, timeout=5) as resp:
              return json.loads(resp.read().decode("utf-8"))

      def get_pod_ip(pod_name):
          try:
              pod = k8s_req("GET", f"/api/v1/namespaces/{SOURCE_NS}/pods/{pod_name}")
              return pod.get("status", {}).get("podIP")
          except Exception:
              return None

      def query_node(ip):
          with psycopg.connect(
              host=ip,
              dbname="shop",
              user="postgres",
              password=PGPASSWORD,
              connect_timeout=3,
              autocommit=True,
          ) as conn:
              in_rec = bool(conn.execute("SELECT pg_is_in_recovery()").fetchone()[0])
              row = conn.execute(
                  "SELECT failover, synced, active, (NOT temporary AND restart_lsn IS NOT NULL AND confirmed_flush_lsn IS NOT NULL) "
                  "FROM pg_replication_slots WHERE slot_name = 'debezium'"
              ).fetchone()
              if row:
                  return in_rec, bool(row[0]), bool(row[1] and row[3]), bool(row[2])
              return in_rec, False, False, False

      def main():
          phase = "pending"
          valid = "true"
          last_patched = None
          while True:
              active = "false"
              ready = "false"
              ip2 = get_pod_ip("shop-2")
              if ip2:
                  try:
                      in_rec2, fail2, sync2, act2 = query_node(ip2)
                      if in_rec2:
                          if fail2 and sync2:
                              phase = "synced"
                      else:
                          if phase != "synced":
                              valid = "false"
                          if fail2 and act2:
                              active = "true"
                  except Exception:
                      pass

              ip1 = get_pod_ip("shop-1")
              if ip1:
                  try:
                      in_rec1, fail1, _, _ = query_node(ip1)
                      if in_rec1 and fail1:
                          ready = "true"
                  except Exception:
                      pass

              curr = {"phase": phase, "valid": valid, "active": active, "ready": ready}
              if curr != last_patched:
                  try:
                      k8s_req(
                          "PATCH",
                          f"/api/v1/namespaces/{VERIFIER_NS}/configmaps/cdc-audit-state",
                          body={"data": curr},
                          content_type="application/merge-patch+json",
                      )
                      last_patched = dict(curr)
                  except Exception:
                      pass
              time.sleep(1.0)

      if __name__ == "__main__":
          main()
    EOT
  }
}

resource "kubernetes_deployment_v1" "slot_auditor" {
  metadata {
    name      = "cdc-verifier-auditor"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "cdc-verifier-auditor"
      }
    }
    template {
      metadata {
        labels = {
          app = "cdc-verifier-auditor"
        }
      }
      spec {
        service_account_name            = kubernetes_service_account_v1.repair.metadata[0].name
        automount_service_account_token = true
        container {
          name              = "auditor"
          image             = var.oracle_image
          image_pull_policy = "IfNotPresent"
          command           = ["python", "/runtime/run.py"]
          env {
            name  = "SOURCE_NAMESPACE"
            value = local.source_namespace
          }
          env {
            name  = "VERIFIER_NAMESPACE"
            value = kubernetes_namespace_v1.verifier.metadata[0].name
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
          volume_mount {
            name       = "runtime"
            mount_path = "/runtime"
            read_only  = true
          }
        }
        volume {
          name = "runtime"
          secret {
            secret_name = kubernetes_secret_v1.auditor_script.metadata[0].name
          }
        }
      }
    }
  }
  wait_for_rollout = true
  depends_on = [
    kubernetes_job_v1.onboarding,
    kubernetes_role_binding_v1.repair_orders_db,
    kubernetes_role_binding_v1.verifier_state_access,
    kubernetes_config_map_v1.audit_state,
  ]
}
