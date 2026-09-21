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

# The corrected connector configuration, applied identically on every arm.
# Unlike eh1-0016, this task's fault is not a wrong value in this file: the
# include-list regex, the signal-table wiring and the topic-routing transform
# are all correct here on base, oracle and violator alike (story.yaml's
# diversion #1 is a solver suspecting otherwise). The fault lives entirely in
# the database -- which tables cdc_publication actually lists -- so this patch
# only ever needs to be applied once, after onboarding.tf's schema migration
# and before the connector's first real start; the oracle repair (repair/
# main.tf) never touches this ConfigMap or rolls this Deployment.
locals {
  connector_properties = templatefile("${path.module}/application.properties.tftpl", {
    kafka_bootstrap        = module.cdc_bus.kafka_bootstrap
    debezium_topic_prefix  = "cdc"
    offsets_topic          = "cdc-offsets"
    schema_history_topic   = "cdc-schema-history"
  })
}

resource "kubernetes_config_map_v1_data" "connector_properties" {
  metadata {
    name      = "debezium-server-config"
    namespace = local.source_namespace
  }
  data          = { "application.properties" = local.connector_properties }
  field_manager = "orders-release-0031"
  force         = true
  # After onboarding.tf: the partitioned schema, the signal table and the
  # publication's own membership all have to exist before this connector's
  # first real start reads them.
  depends_on = [
    module.scene_cdc,
    kubectl_manifest.kafka_user,
    kubernetes_job_v1.onboarding,
  ]
}

# application.properties is not hot-reloaded by Debezium Server, so this
# content change needs an explicit rollout; the checksum annotation is what
# makes that rollout happen exactly when (and only when) the rendered file
# changes. Because the corrected configuration is arm-independent, this
# rollout happens once, during initial provisioning, on every arm -- it is not
# part of the oracle repair.
resource "kubectl_manifest" "connector_rollout" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = "debezium-server", namespace = local.source_namespace }
    spec = {
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
  field_manager     = "orders-release-0031-connector"
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = true
  depends_on        = [kubernetes_config_map_v1_data.connector_properties, kubernetes_secret_v1.source_kafka]
}

# Per-principal Kafka identities, the same pattern eh1-0012 and eh1-0016 use.
# cdc-source (the debezium-server Deployment) may write/describe cdc.public.*
# -- which after the router transform includes cdc.public.orders itself, the
# per-partition-table topics it is rewritten from, customers, products,
# order_items and debezium_signal -- plus read/write/describe its own offsets
# and schema-history topics. Create is granted on the cdc.public. prefix too:
# cdc.public.debezium_signal is never auto-created during an earlier
# unauthenticated window the way the other cdc.public.* topics are (the
# connector's first, pre-auth life runs a placeholder config that never
# includes the signal table), so this principal has to be able to create it
# itself once authorization is on. cdc-observer (the protected verifier) may
# only read/describe cdc.public.* and describe the two internal topics.
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
