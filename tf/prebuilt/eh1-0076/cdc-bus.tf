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

# Kafka bus composition for eh1-0076 using Strimzi with SCRAM-SHA-512 auth.
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
        listeners = [{
          name           = "plain"
          port           = 9092
          type           = "internal"
          tls            = false
          authentication = { type = "scram-sha-512" }
        }]
        authorization = { type = "simple" }
      })
    })
  }))
  apply_only        = true
  field_manager     = "platform-kafka-auth"
  server_side_apply = true
  force_conflicts   = true
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [module.cdc_bus, kubernetes_job_v1.onboarding]
}
