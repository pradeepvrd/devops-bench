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

# The second resource manager. The ledger is its own CloudNativePG cluster in its own
# namespace, run by the operator the cdc scene already installs, so it needs no image or
# entrypoint of its own and behaves exactly as Cluster/shop does.
#
# It holds the other half of the answer: the ledger branch's state for every batch in
# xa_txn_log, pg_prepared_xacts and ledger_entries, and the coordinator's own records --
# its decision journal in recon.xa_decisions and its batch registry in recon.batches.
# Two of the stranded batches are in doubt here too, so the ledger must accept prepared
# transactions; it is created with the setting, so unlike Cluster/shop it needs no
# restart to take it.
resource "kubernetes_namespace_v1" "ledger" {
  metadata {
    name = local.ledger_namespace
    labels = {
      "living-stack"           = "primary"
      "living-stack-component" = "ledger"
    }
  }
}

resource "kubectl_manifest" "ledger_cluster" {
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = "ledger"
      namespace = kubernetes_namespace_v1.ledger.metadata[0].name
      labels = {
        "living-stack"           = "primary"
        "living-stack-component" = "ledger"
      }
    }
    spec = {
      instances             = 1
      imageName             = "ghcr.io/cloudnative-pg/postgresql:18.6"
      enableSuperuserAccess = true
      bootstrap = {
        initdb = {
          database = "ledger"
          owner    = "ledger"
        }
      }
      postgresql = {
        parameters = {
          max_prepared_transactions        = "10"
          client_connection_check_interval = "10s"
        }
      }
      storage = { size = "1Gi" }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }
  })
  server_side_apply = true

  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  timeouts { create = "10m" }

  depends_on = [module.scene_cdc, kubernetes_namespace_v1.ledger]
}

data "kubernetes_secret_v1" "ledger_superuser" {
  metadata {
    name      = "ledger-superuser"
    namespace = kubernetes_namespace_v1.ledger.metadata[0].name
  }
  depends_on = [kubectl_manifest.ledger_cluster]
}

resource "kubernetes_secret_v1" "ledger_credentials" {
  metadata {
    name      = "orders-release-0076-ledger"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  data = {
    password = data.kubernetes_secret_v1.ledger_superuser.data["password"]
  }
}
