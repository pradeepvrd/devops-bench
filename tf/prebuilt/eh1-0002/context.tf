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

# Authored change metadata belongs on the affected workload, not in a policy ConfigMap.
resource "kubernetes_annotations" "writer_context" {
  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = "oltp-writer"
    namespace = "orders-db"
  }
  annotations = {
    "kubernetes.io/change-cause"                              = "Load exercise ended; normal operating allocation is one writer replica with one connection worker. Restore the application allocation after the exercise. Database capacity review remains separate."
    "operations.living-stacks.io/baseline-replicas"           = "1"
    "operations.living-stacks.io/baseline-connection-workers" = "1"
    "operations.living-stacks.io/min-retry-backoff-seconds"   = "5"
  }
  depends_on = [module.scene_cdc]
}
resource "kubernetes_annotations" "database_context" {
  api_version = "postgresql.cnpg.io/v1"
  kind        = "Cluster"
  metadata {
    name      = "shop"
    namespace = "orders-db"
  }
  annotations = {
    "operations.living-stacks.io/incident-max-connections" = "20"
    "kubernetes.io/change-cause"                           = "Capacity allocation: max_connections 20. A restart-required capacity increase needs a separate maintenance change with logical-slot continuity verified on the promoted instance."
  }
  depends_on = [module.scene_cdc]
}
