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

# The coordinator. Its Deployment is created with no replicas before the seed, so its
# ReplicaSet exists and the seed can name the pod the crashed run was on after it: a pod
# of this same ReplicaSet, which the one running now replaced. It is scaled up only once
# the seed has stranded the batches, so its pod is younger than the prepared
# transactions -- consistent with a coordinator that came back after the batches its
# previous run abandoned.
#
# It is live: it journals its start and carries on from the run before it. Its recovery
# presumes the batch that run never decided aborted and re-queues its invoices as a new
# batch, recon-0013, but it never rolls back the undecided batch's in-doubt branches, so
# recon-0013 waits on their row locks, first on the shop and then on the ledger. Nor
# does it finish the two batches that run decided. Its configuration says where its
# journal lives and which protocol it runs, which is how an operator finds what it
# decided -- and what it has not decided yet.
#
# Recreate, so a rollout never runs two coordinators at once, and the pod's name in the
# environment, which the coordinator journals when it starts.
resource "kubernetes_secret_v1" "payments_recon_ledger" {
  metadata {
    name      = "payments-recon-ledger"
    namespace = local.source_namespace
  }
  data = {
    password = data.kubernetes_secret_v1.ledger_superuser.data["password"]
  }
}

resource "kubernetes_deployment_v1" "payments_recon" {
  metadata {
    name      = "payments-recon"
    namespace = local.source_namespace
    labels    = { app = "payments-recon" }
    annotations = {
      "ops.platform/change-record" = "CHG-5120"
    }
  }
  spec {
    replicas = 0
    selector { match_labels = { app = "payments-recon" } }
    strategy { type = "Recreate" }
    template {
      metadata { labels = { app = "payments-recon" } }
      spec {
        container {
          name              = "coordinator"
          image             = var.oracle_image
          image_pull_policy = "IfNotPresent"
          command           = ["python", "-u", "/app/coordinator.py"]
          env_from {
            config_map_ref { name = "payments-recon-config" }
          }
          env {
            name = "POD_NAME"
            value_from {
              field_ref { field_path = "metadata.name" }
            }
          }
          env {
            name = "SHOP_PASSWORD"
            value_from {
              secret_key_ref {
                name = "shop-superuser"
                key  = "password"
              }
            }
          }
          env {
            name = "LEDGER_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.payments_recon_ledger.metadata[0].name
                key  = "password"
              }
            }
          }
          volume_mount {
            name       = "app"
            mount_path = "/app"
            read_only  = true
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }
        }
        volume {
          name = "app"
          config_map { name = "payments-recon-entrypoint" }
        }
      }
    }
  }
  wait_for_rollout = false

  depends_on = [kubectl_manifest.objects, kubernetes_secret_v1.payments_recon_ledger]
}

# Once the crash state exists and change capture has caught up with it, the coordinator
# comes back. Only the replica count changes, so its pod belongs to the ReplicaSet the
# seed named the crashed run's pod after.
resource "kubectl_manifest" "payments_recon_start" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = "payments-recon", namespace = local.source_namespace }
    spec       = { replicas = 1 }
  })
  apply_only        = true
  field_manager     = "payments-platform"
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = true

  depends_on = [kubernetes_deployment_v1.payments_recon, kubernetes_job_v1.seed, kubernetes_job_v1.drain]
}
