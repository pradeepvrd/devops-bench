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

# Materialize real initial evidence before the first hold sample. A Deployment
# without a readiness probe is not evidence that CDC has connected or writes work.
resource "kubernetes_job_v1" "cdc_ready" {
  metadata {
    name      = "cdc-readiness"
    namespace = "orders-db"
  }
  spec {
    backoff_limit           = 0
    active_deadline_seconds = 300
    template {
      metadata {}
      spec {
        restart_policy = "Never"
        container {
          name  = "check"
          image = "ghcr.io/cloudnative-pg/postgresql:18.6"
          command = ["sh", "-c", <<-EOT
            set -eu
            export PGCONNECT_TIMEOUT=5
            for attempt in $(seq 1 55); do
              psql -v ON_ERROR_STOP=1 -tAc "
                INSERT INTO customers (name, email, tier)
                SELECT 'seed-customer-init-' || g, 'seed-init-' || g || '@example.test', 'standard'
                FROM generate_series(1, 20) AS g
                WHERE NOT EXISTS (SELECT 1 FROM customers);
                INSERT INTO products (name, category, price, stock)
                SELECT 'seed-product-init-' || g, 'electronics', 19.99, 100
                FROM generate_series(1, 10) AS g
                WHERE NOT EXISTS (SELECT 1 FROM products);
                INSERT INTO orders (customer_id, status, total)
                SELECT (SELECT id FROM customers LIMIT 1), 'pending', 19.99
                WHERE NOT EXISTS (SELECT 1 FROM orders WHERE created_at > now() - interval '2 minutes');
              " >/dev/null 2>&1 || true
              result=$(psql -v ON_ERROR_STOP=1 -tAc "SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='debezium' AND active) AND EXISTS (SELECT 1 FROM orders WHERE created_at > now()-interval '2 minutes') AND (SELECT count(*) FROM pg_stat_activity WHERE usename='app' AND backend_type='client backend') >= ${var.arm == "oracle" ? 1 : 10}") || result=f
              if [ "$result" = t ]; then echo "CDC slot active and recent order writes observed"; exit 0; fi
              sleep 5
            done
            echo "CDC readiness evidence did not materialize" >&2
            exit 1
          EOT
          ]
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
        }
      }
    }
  }
  wait_for_completion = true
  timeouts { create = "6m" }
  depends_on = [module.scene_cdc]
}
resource "kubernetes_role_v1" "bus_observer" {
  metadata {
    name      = "bench-bus-observer"
    namespace = "cdc-bus"
  }
  rule {
    api_groups = ["kafka.strimzi.io"]
    resources  = ["kafkas", "kafkatopics", "kafkanodepools", "strimzipodsets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "events", "configmaps"]
    verbs      = ["get", "list", "watch"]
  }
  depends_on = [module.cdc_bus]
}
resource "kubernetes_role_binding_v1" "bus_observer" {
  metadata {
    name      = "bench-bus-observer"
    namespace = "cdc-bus"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.bus_observer.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "bench-agent"
    namespace = "bench-system"
  }
  depends_on = [module.bench_agent]
}
