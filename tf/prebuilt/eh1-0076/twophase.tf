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

# Two-phase commit must be enabled before anything can be prepared, and
# max_prepared_transactions defaults to 0. The scene renders Cluster/shop to .rendered/
# and applies it; this overlays three fields onto that manifest -- the same technique
# cdc-bus.tf uses on the Kafka CR -- so every other field stays whatever the scene set.
#
# primaryUpdateMethod: the scene sets switchover so restart-required changes roll through
# a standby. This task runs a single instance, so there is no standby to switch to;
# restart makes the rollout of a postmaster parameter deterministic instead of relying
# on how the operator treats a switchover with nothing to switch to.
data "local_file" "shop_cluster_base" {
  filename   = "${path.module}/.rendered/cdc-cnpg-cluster-${local.source_namespace}.yaml"
  depends_on = [module.scene_cdc]
}

locals {
  shop_cluster_base = yamldecode(data.local_file.shop_cluster_base.content)

  shop_cluster_twophase = merge(local.shop_cluster_base, {
    spec = merge(local.shop_cluster_base.spec, {
      primaryUpdateMethod = "restart"
      postgresql = merge(local.shop_cluster_base.spec.postgresql, {
        parameters = merge(local.shop_cluster_base.spec.postgresql.parameters, {
          max_prepared_transactions = "10"
          # A backend waiting on a lock notices within ten seconds that its client has
          # gone, so a coordinator pod that is replaced leaves no session behind it.
          client_connection_check_interval = "10s"
        })
      })
    })
  })
}

resource "kubectl_manifest" "shop_twophase" {
  yaml_body         = yamlencode(local.shop_cluster_twophase)
  apply_only        = true
  server_side_apply = true
  force_conflicts   = true
  field_manager     = "dba-chg-5120"

  depends_on = [module.scene_cdc]
}

# The operator restarts the instance to apply a postmaster parameter. Nothing that needs
# the database runs until the setting is live -- onboarding in particular, which would
# otherwise race the restart.
resource "kubernetes_job_v1" "wait_twophase" {
  metadata {
    name      = "orders-twophase-0076"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  spec {
    backoff_limit = 0
    template {
      metadata { name = "orders-twophase-0076" }
      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        container {
          name              = "wait"
          image             = "ghcr.io/cloudnative-pg/postgresql:18.6"
          image_pull_policy = "IfNotPresent"
          command = ["bash", "-c", <<-EOT
            for i in $(seq 1 120); do
              n=$(psql -h shop-rw.${local.source_namespace}.svc -U postgres -d shop -tAX -c "SHOW max_prepared_transactions" 2>/dev/null || echo 0)
              if [ "$${n:-0}" -gt 0 ]; then echo "two-phase commit enabled: max_prepared_transactions=$n"; exit 0; fi
              echo "waiting for the instance to restart with two-phase commit enabled"
              sleep 5
            done
            echo "max_prepared_transactions never became non-zero; the Cluster overlay did not roll out" >&2
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
  timeouts { create = "12m" }

  depends_on = [kubectl_manifest.shop_twophase]
}
