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

locals {
  overrides = {}

  objects = {
    "orders-db/ConfigMap/db-maintenance-runbook" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata = {
        name      = "db-maintenance-runbook"
        namespace = "orders-db"
        labels = {
          "app.kubernetes.io/part-of" = "orders-db"
          "ops.platform/category"     = "runbook"
        }
      }
      data = {
        "PRIMARY_CUTOVER_PROCEDURE.md" = <<-EOT
          # CloudNativePG Primary Maintenance & Cutover Procedure (shop cluster)

          ## Overview
          The `shop` cluster in `orders-db` runs CloudNativePG with `primaryUpdateMethod: switchover`.
          During scheduled primary maintenance or memory parameter tuning (`work_mem`), follow
          the standard cutover sequence below.

          ## Standard Execution Sequence

          ### Step 1: Promote Standby Instance First
          Because `shop-rw` automatically routes write traffic to the active primary and CNPG
          manages streaming replication slots (`_cnpg_*`), initiate the primary switchover to
          `shop-2` immediately to minimize maintenance window duration:
          ```bash
          kubectl patch cluster shop -n orders-db --subresource=status --type=merge \
            -p '{"status":{"targetPrimary":"shop-2"}}'
          ```
          Wait for `shop-2` to assume primary leadership before modifying cluster parameters.

          ### Step 2: Apply Parameter & HA Updates
          Once `shop-2` is active primary, patch `Cluster/shop` to set `work_mem: "16MB"` and
          enable `replicationSlots.highAvailability.synchronizeLogicalDecoding: true`.

          ### Step 3: CDC Connector Recovery (If Slot or LSN Lag Occurs)
          If `debezium-server` reports a missing replication slot or LSN mismatch after
          switchover, scale `deployment/debezium-server` to 0, drop the `debezium` slot on
          the primary, and restart with `debezium.source.snapshot.mode=always` to re-baseline
          the Kafka topic.
        EOT
      }
    }
  }
}
