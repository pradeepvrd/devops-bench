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
  connector_properties = templatefile("${path.module}/application.properties.tftpl", {
    kafka_bootstrap       = module.cdc_bus.kafka_bootstrap
    debezium_topic_prefix = "cdc"
    offsets_topic         = "cdc-offsets"
    schema_history_topic  = "cdc-schema-history"
  })
}

# Scale the scene's default debezium-server to zero before onboarding runs.
#
# module.scene_cdc brings the connector up with the scene's stock
# configuration, before this task has supplied the Kafka credentials or its own
# application.properties. That premature connector still reaches Postgres and
# claims the "debezium" replication slot, which onboarding.sql must drop and
# recreate with failover => true. Because the connector retries forever
# (errors.max.retries=-1) it wins that race nondeterministically.
#
# Quiescing here removes the race by construction rather than by timing:
# kubernetes_job_v1.onboarding depends on this, and connector_rollout below
# scales the connector back to one replica once the real configuration is in
# place.
resource "kubectl_manifest" "connector_quiesce" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = "debezium-server", namespace = local.source_namespace }
    spec       = { replicas = 0 }
  })
  apply_only        = true
  field_manager     = "orders-release-0034-quiesce"
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = true
  depends_on        = [module.scene_cdc]
}

resource "kubernetes_config_map_v1_data" "connector_properties" {
  metadata {
    name      = "debezium-server-config"
    namespace = local.source_namespace
  }
  data          = { "application.properties" = local.connector_properties }
  field_manager = "orders-release-0034"
  force         = true
  depends_on = [
    module.scene_cdc,
    kubectl_manifest.kafka_user,
    kubernetes_job_v1.onboarding,
  ]
}

resource "kubectl_manifest" "connector_rollout" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = "debezium-server", namespace = local.source_namespace }
    spec = {
      # Restores the replica count dropped to zero by connector_quiesce. The
      # connector comes back only after onboarding has established the
      # failover-eligible slot and the task's application.properties are in
      # the ConfigMap.
      replicas = 1
      template = {
        metadata = { annotations = { "checksum/application-properties" = sha256(local.connector_properties) } }
        spec = {
          containers = [{
            name = "debezium-server",
            env = [{
              name      = "CDC_KAFKA_PASSWORD",
              valueFrom = { secretKeyRef = { name = kubernetes_secret_v1.source_kafka.metadata[0].name, key = "password" } }
            }]
          }]
        }
      }
    }
  })
  apply_only        = true
  field_manager     = "orders-release-0034-connector"
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = true
  depends_on = [
    kubernetes_config_map_v1_data.connector_properties,
    kubernetes_secret_v1.source_kafka,
    kubectl_manifest.connector_quiesce,
  ]
}

locals {
  source_acls = concat(
    [{ resource = { type = "topic", name = "cdc.public.", patternType = "prefix" }, operations = ["Write", "Describe", "Create"], host = "*" }],
    [for name in ["cdc-offsets", "cdc-schema-history"] : {
      resource = { type = "topic", name = name, patternType = "literal" }, operations = ["Read", "Write", "Describe"], host = "*"
    }],
    [{ resource = { type = "group", name = "*", patternType = "literal" }, operations = ["Read"], host = "*" },
    { resource = { type = "cluster" }, operations = ["IdempotentWrite"], host = "*" }],
  )
  observer_acls = concat(
    [{ resource = { type = "topic", name = "cdc.public.", patternType = "prefix" }, operations = ["Read", "Describe"], host = "*" }],
    [for name in ["cdc-offsets", "cdc-schema-history"] : {
      resource = { type = "topic", name = name, patternType = "literal" }, operations = ["Describe"], host = "*"
    }],
  )
}

resource "kubectl_manifest" "kafka_user" {
  for_each = { cdc-source = local.source_acls, cdc-observer = local.observer_acls }
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaUser"
    metadata   = { name = each.key, namespace = local.bus_namespace, labels = { "strimzi.io/cluster" = "kafka" } }
    spec       = { authentication = { type = "scram-sha-512" }, authorization = { type = "simple", acls = each.value } }
  })
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
  depends_on = [kubectl_manifest.kafka_auth]
}

data "kubernetes_secret_v1" "kafka_user" {
  for_each = toset(["cdc-source", "cdc-observer"])
  metadata {
    name      = each.key
    namespace = local.bus_namespace
  }
  depends_on = [kubectl_manifest.kafka_user]
}

resource "kubernetes_secret_v1" "source_kafka" {
  metadata {
    name      = "debezium-kafka-credentials"
    namespace = local.source_namespace
  }
  data       = { password = data.kubernetes_secret_v1.kafka_user["cdc-source"].data["password"] }
  depends_on = [module.scene_cdc]
}
