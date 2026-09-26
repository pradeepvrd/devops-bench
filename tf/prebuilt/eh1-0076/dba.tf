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

# The database team's investigation, left open. Someone from the team that flagged the
# table ran psql in a debug pod, opened a REPEATABLE READ transaction to read the table's
# statistics, and walked away: the session sits idle in that transaction, holding a
# snapshot. It began after the crash, so its snapshot is newer than recon-0010's prepared
# xid and VACUUM's cutoff is recon-0010's until the prepared transactions are resolved;
# then it is this session's. It has written nothing. A bare pod that never restarts, as
# `kubectl run --restart=Never` makes: once its session is ended, nothing brings it back.
resource "kubernetes_pod_v1" "dba_psql" {
  metadata {
    name      = "dba-psql"
    namespace = local.source_namespace
    labels    = { run = "dba-psql" }
  }
  spec {
    restart_policy = "Never"
    container {
      name              = "dba-psql"
      image             = "ghcr.io/cloudnative-pg/postgresql:18.6"
      image_pull_policy = "IfNotPresent"
      stdin             = true
      command = ["bash", "-c", <<-EOT
        { printf '%s\n' "BEGIN ISOLATION LEVEL REPEATABLE READ;" \
            "SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, autovacuum_count FROM pg_stat_user_tables WHERE relname = 'orders';"
          exec cat; } | psql -h shop-rw.${local.source_namespace}.svc -U postgres -d shop
      EOT
      ]
      env {
        name = "PGPASSWORD"
        value_from {
          secret_key_ref {
            name = "shop-superuser"
            key  = "password"
          }
        }
      }
    }
  }
  depends_on = [kubernetes_job_v1.seed, kubernetes_job_v1.drain]
}
