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

# Bus-only composition, same shape as eh1-0012's and eh1-0016's cdc-bus.tf: no
# Flink or streaming generators are deployed. SCRAM-SHA-512 plus per-principal
# ACLs are layered on top of the bus module's own default listener, the same
# pattern eh1-0012 and eh1-0016 already use: a plaintext, unauthenticated
# listener would let any pod reachable on the cluster network (including one
# the solver stands up in its own orders-db edit namespace) publish directly
# onto cdc.public.orders, satisfying the delivery half of the orders objective
# without ever touching the seeded publication gap.
resource "kubernetes_namespace_v1" "cdc_bus" {
  metadata { name = local.bus_namespace }
}

module "cdc_bus" {
  source     = "../../modules/living-stacks/streaming/tf/modules/kafka_strimzi"
  namespace  = kubernetes_namespace_v1.cdc_bus.metadata[0].name
  system     = "primary"
  kubeconfig = var.kubeconfig_path
  depends_on = [module.image_preload]
}

# Read the exact full Kafka document the pinned bus module rendered, then
# change only the two keys below. Applying a partial SSA document after its
# own client-side apply migrates ownership and can prune fields it omits; a
# unique field manager alone does not prevent that.
data "local_file" "kafka_base" {
  filename   = "${path.module}/.rendered/streaming-kafka-cdc-bus.yaml"
  depends_on = [module.cdc_bus]
}

locals {
  kafka_base_manifest = yamldecode(data.local_file.kafka_base.content)
}

resource "kubectl_manifest" "kafka_auth" {
  yaml_body = yamlencode(merge(local.kafka_base_manifest, {
    spec = merge(local.kafka_base_manifest.spec, {
      kafka = merge(local.kafka_base_manifest.spec.kafka, {
        listeners = [{ name = "plain", port = 9092, type = "internal", tls = false,
        authentication = { type = "scram-sha-512" } }]
        authorization = { type = "simple" }
      })
    })
  }))
  apply_only        = true # The pinned module owns deletion of this shared Kafka CR.
  field_manager     = "orders-release-0031-auth"
  server_side_apply = true
  force_conflicts   = true
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  # After onboarding: the scene's own base topics (customers, products,
  # order_items, plus whatever orders/orders_YYYY_MM/debezium_signal topics the
  # connector's own auto-topic-creation makes) must already exist under the
  # unauthenticated bootstrap listener before authorization turns on, since
  # this task adds no KafkaTopic CR of its own.
  depends_on = [module.cdc_bus, kubernetes_job_v1.onboarding]
}
