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

# The fault. seed/seed.sh builds the order history, runs twelve reconciliation batches
# as two-phase commits, strands the last three prepared at three points of the protocol,
# writes the ledger's side and the coordinator's journal anchored on the server's own
# prepare times, and then generates the traffic whose dead tuples vacuum is not allowed
# to remove.
#
# It runs from cdc-verifier, which the solver cannot read, and it is not idempotent -- a
# second run would try to prepare gids that already exist -- so it gets no retries.
resource "kubernetes_secret_v1" "seed_script" {
  metadata {
    name      = "orders-release-0076-seed"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  data = { "seed.sh" = file("${path.module}/seed/seed.sh") }
}

# The journal records the pod the crashed run was on. It was a pod of the coordinator's
# own ReplicaSet, so the seed reads that ReplicaSet's name before writing it, and it
# publishes that run's last log lines as the on-call's crash report.
resource "kubernetes_service_account_v1" "seed" {
  metadata {
    name      = "orders-seed-0076"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
}

resource "kubernetes_role_v1" "seed_replicasets" {
  metadata {
    name      = "orders-seed-0076-replicasets"
    namespace = local.source_namespace
  }
  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["create"]
  }
  depends_on = [module.scene_cdc]
}

resource "kubernetes_role_binding_v1" "seed_replicasets" {
  metadata {
    name      = "orders-seed-0076-replicasets"
    namespace = local.source_namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.seed_replicasets.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.seed.metadata[0].name
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
}

resource "kubernetes_job_v1" "seed" {
  metadata {
    name      = "orders-seed-0076"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  spec {
    backoff_limit = 0
    template {
      metadata { name = "orders-seed-0076" }
      spec {
        restart_policy                  = "Never"
        service_account_name            = kubernetes_service_account_v1.seed.metadata[0].name
        automount_service_account_token = true
        init_container {
          name              = "crashed-pod"
          image             = var.oracle_image
          image_pull_policy = "IfNotPresent"
          command = ["python", "-c", <<-EOT
            import json, ssl, time, urllib.request
            token = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
            ctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
            url = "https://kubernetes.default.svc/apis/apps/v1/namespaces/${local.source_namespace}/replicasets?labelSelector=app%3Dpayments-recon"
            for attempt in range(60):
                req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
                items = json.loads(urllib.request.urlopen(req, context=ctx, timeout=10).read())["items"]
                if items:
                    name = items[0]["metadata"]["name"]
                    open("/work/old_pod", "w").write(name + "-x2mqp")
                    print("the crashed run's pod: " + name + "-x2mqp")
                    break
                time.sleep(2)
            else:
                raise SystemExit("payments-recon has no ReplicaSet")
          EOT
          ]
          volume_mount {
            name       = "work"
            mount_path = "/work"
          }
        }
        init_container {
          name              = "seed"
          image             = "ghcr.io/cloudnative-pg/postgresql:18.6"
          image_pull_policy = "IfNotPresent"
          command = ["bash", "-ec", <<-EOT
            export SHOP_URL="host=shop-rw.${local.source_namespace}.svc user=postgres dbname=shop password=$SHOP_PASSWORD"
            export LEDGER_URL="host=ledger-rw.${local.ledger_namespace}.svc user=postgres dbname=ledger password=$LEDGER_PASSWORD"
            export OLD_POD="$(cat /work/old_pod)"
            bash /seed/seed.sh
          EOT
          ]
          env {
            name = "SHOP_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.verifier_credentials.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name = "LEDGER_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.ledger_credentials.metadata[0].name
                key  = "password"
              }
            }
          }
          volume_mount {
            name       = "seed"
            mount_path = "/seed"
            read_only  = true
          }
          volume_mount {
            name       = "work"
            mount_path = "/work"
          }
        }
        # The on-call's crash report: the crashed run's last log lines, which the seed rebuilt
        # from the same instants as the journal. Published where the on-call would leave it.
        container {
          name              = "crash-report"
          image             = var.oracle_image
          image_pull_policy = "IfNotPresent"
          command = ["python", "-c", <<-EOT
            import json, ssl, urllib.request
            token = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
            ctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
            body = {"apiVersion": "v1", "kind": "ConfigMap",
                    "metadata": {"name": "payments-recon-crash-report", "namespace": "${local.source_namespace}",
                                 "labels": {"app": "payments-recon"}},
                    "data": {"last-log-lines.txt": open("/work/crash-report.txt").read()}}
            req = urllib.request.Request(
                "https://kubernetes.default.svc/api/v1/namespaces/${local.source_namespace}/configmaps?fieldManager=kubectl-create",
                data=json.dumps(body).encode(), method="POST",
                headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            urllib.request.urlopen(req, context=ctx, timeout=10)
            print("published ConfigMap/payments-recon-crash-report")
          EOT
          ]
          volume_mount {
            name       = "work"
            mount_path = "/work"
            read_only  = true
          }
        }
        volume {
          name = "seed"
          secret { secret_name = kubernetes_secret_v1.seed_script.metadata[0].name }
        }
        volume {
          name = "work"
          empty_dir {}
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "15m" }

  depends_on = [
    kubernetes_job_v1.wait_twophase,
    kubernetes_job_v1.onboarding,
    kubectl_manifest.connector_rollout,
    kubectl_manifest.ledger_cluster,
    kubernetes_deployment_v1.payments_recon,
    kubernetes_role_binding_v1.seed_replicasets,
  ]
}

# The seed emits a few hundred thousand change events. Wait for the connector to confirm
# its way through them, so that at the start of the turn change capture really is keeping
# up, as the ticket says. This measures confirmed_flush_lsn, which keeps advancing; the
# slot's restart point does not, and waiting on it would never finish.
resource "kubernetes_job_v1" "drain" {
  metadata {
    name      = "orders-drain-0076"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  spec {
    backoff_limit = 0
    template {
      metadata { name = "orders-drain-0076" }
      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        container {
          name              = "wait-for-capture"
          image             = "ghcr.io/cloudnative-pg/postgresql:18.6"
          image_pull_policy = "IfNotPresent"
          command = ["bash", "-c", <<-EOT
            for i in $(seq 1 240); do
              lag=$(psql -h shop-rw.${local.source_namespace}.svc -U postgres -d shop -tAX -c "SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn), 1e12)::bigint FROM pg_replication_slots WHERE slot_name = 'debezium'" 2>/dev/null || echo 999999999)
              if [ "$${lag:-999999999}" -lt 16777216 ]; then echo "connector caught up; lag=$${lag} bytes"; exit 0; fi
              echo "waiting for the connector to confirm through the seed; lag=$${lag} bytes"
              sleep 5
            done
            echo "the connector never caught up with the seed" >&2
            exit 1
          EOT
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
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "22m" }

  depends_on = [kubernetes_job_v1.seed]
}
