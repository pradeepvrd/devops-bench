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

# Strimzi operator (helm, native fit) + the Kafka/KafkaNodePool/KafkaTopic CRs
# (no native Terraform resource for kafka.strimzi.io/v1 in this codebase's
# provider set, so they go through the alekc/kubectl provider's
# kubectl_manifest resource, matching ../../../cdc/tf/modules/cnpg_postgres's
# own precedent for the same problem with postgresql.cnpg.io/v1 Cluster).

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}

locals {
  topic_dot     = var.topic_prefix != "" ? "${var.topic_prefix}." : ""
  resource_dash = var.topic_prefix != "" ? "${var.topic_prefix}-" : ""
  # Mirrors streaming/base/kafka-topics.yaml (events-raw, events-agg) plus
  # overlays/gke/kafka-topics-enrichment.yaml (orders-enriched,
  # product-activity, events-product-enriched).
  streaming_topics = {
    events_raw = {
      resource_name = "${local.resource_dash}events-raw"
      topic_name    = "${local.topic_dot}events.raw"
      partitions    = 6
      config        = merge({ "retention.ms" = "3600000" }, lookup(var.topic_config_overrides, "events_raw", {}))
    }
    events_agg = {
      resource_name = "${local.resource_dash}events-agg"
      topic_name    = "${local.topic_dot}events.agg"
      partitions    = 3
      config        = merge({ "retention.ms" = "3600000" }, lookup(var.topic_config_overrides, "events_agg", {}))
    }
    orders_enriched = {
      resource_name = "${local.resource_dash}orders-enriched"
      topic_name    = "${local.topic_dot}orders.enriched"
      partitions    = 3
      config        = merge({ "retention.ms" = "3600000" }, lookup(var.topic_config_overrides, "orders_enriched", {}))
    }
    product_activity = {
      resource_name = "${local.resource_dash}product-activity"
      topic_name    = "${local.topic_dot}product.activity"
      partitions    = 3
      config        = merge({ "retention.ms" = "3600000" }, lookup(var.topic_config_overrides, "product_activity", {}))
    }
    events_product_enriched = {
      resource_name = "${local.resource_dash}events-product-enriched"
      topic_name    = "${local.topic_dot}events.product-enriched"
      partitions    = 6
      config        = merge({ "retention.ms" = "3600000" }, lookup(var.topic_config_overrides, "events_product_enriched", {}))
    }
  }

  # cdc.public.* (the four dimension/fact topics Debezium publishes to) plus
  # Debezium's own offset/schema-history topics: the exact six topics
  # ../../../cdc/tf/manifests/kafka-topics.yaml applies today. cdc/tf/scene
  # deliberately does not create these itself ("cdc never creates its own
  # Kafka", cdc/README.md) and exposes debezium_topic_prefix/offsets_topic/
  # schema_history_topic as scene outputs specifically so this module could
  # take ownership of them instead (see cdc/tf/scene/README.md "What it
  # deliberately does not create"). Confirmed live during this module's own
  # validation that this isn't optional: Strimzi's Kafka CR here does not
  # enable auto.create.topics.enable, so a Flink Kafka source against a
  # nonexistent cdc.public.* topic fails hard
  # (UnknownTopicOrPartitionException) rather than lazily creating it, which
  # is what enrichment-orders.sql/enrichment-events.sql's cdc.public.*
  # sources need to even reach RUNNING, independent of whether any cdc stack
  # is actually producing to them.
  cdc_topics = var.create_cdc_topics ? {
    cdc_public_customers = {
      resource_name = "${local.resource_dash}cdc-public-customers"
      topic_name    = "${var.debezium_topic_prefix}.public.customers"
      partitions    = 3
      config        = merge({ "retention.ms" = "86400000" }, lookup(var.topic_config_overrides, "cdc_public_customers", {}))
    }
    cdc_public_products = {
      resource_name = "${local.resource_dash}cdc-public-products"
      topic_name    = "${var.debezium_topic_prefix}.public.products"
      partitions    = 3
      config        = merge({ "retention.ms" = "86400000" }, lookup(var.topic_config_overrides, "cdc_public_products", {}))
    }
    cdc_public_orders = {
      resource_name = "${local.resource_dash}cdc-public-orders"
      topic_name    = "${var.debezium_topic_prefix}.public.orders"
      partitions    = 3
      config        = merge({ "retention.ms" = "86400000" }, lookup(var.topic_config_overrides, "cdc_public_orders", {}))
    }
    cdc_public_order_items = {
      resource_name = "${local.resource_dash}cdc-public-order-items"
      topic_name    = "${var.debezium_topic_prefix}.public.order_items"
      partitions    = 3
      config        = merge({ "retention.ms" = "86400000" }, lookup(var.topic_config_overrides, "cdc_public_order_items", {}))
    }
    cdc_offsets = {
      resource_name = "${local.resource_dash}cdc-offsets"
      topic_name    = var.offsets_topic
      partitions    = 1
      config        = merge({ "cleanup.policy" = "compact" }, lookup(var.topic_config_overrides, "cdc_offsets", {}))
    }
    cdc_schema_history = {
      resource_name = "${local.resource_dash}cdc-schema-history"
      topic_name    = var.schema_history_topic
      partitions    = 1
      config        = merge({ "cleanup.policy" = "delete", "retention.ms" = "-1" }, lookup(var.topic_config_overrides, "cdc_schema_history", {}))
    }
  } : {}

  topics = merge(local.streaming_topics, local.cdc_topics)
}

resource "helm_release" "strimzi" {
  name       = "strimzi-kafka-operator"
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  version    = var.strimzi_chart_version
  namespace  = var.namespace

  # var.namespace is created by the caller (streaming/tf/scene), same
  # convention as cdc/tf/scene creating its own namespace and passing it into
  # every module: this module never creates the namespace it installs into.
  create_namespace = false

  # strimzi-kafka-operator is installed once per namespace (namespace-scoped
  # watch, matching stack.sh), but its ClusterRoles/ClusterRoleBindings are
  # cluster-scoped and fixed-named: a second instance on the same cluster
  # must skip re-creating those. Mirrors stack.sh's strimzi_helm_args().
  set {
    name  = "createGlobalResources"
    value = var.create_global_resources
  }

  set {
    name  = "generateNetworkPolicy"
    value = var.generate_network_policy
  }

  # helm's own --wait, matching stack.sh's `--wait --timeout 5m`.
  wait    = true
  timeout = 300
}

resource "null_resource" "wait_for_crds" {
  depends_on = [helm_release.strimzi]

  triggers = {
    strimzi_chart_version = var.strimzi_chart_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # kubectl's own built-in CRD readiness condition, a near-verbatim port of
    # stack.sh's wait_for_crd(), looped over the three CRDs this module
    # depends on.
    command = <<-EOT
      set -e
      for crd in kafkas.kafka.strimzi.io kafkanodepools.kafka.strimzi.io kafkatopics.kafka.strimzi.io; do
        kubectl --kubeconfig ${var.kubeconfig} wait --for=condition=Established "crd/$crd" --timeout=180s
      done
    EOT
  }
}

locals {
  # kafka_cr_overrides.listeners replaces this single internal:9092 listener
  # wholesale when set (a listener list has no natural per-entry merge key
  # this repo's flat merge()/coalesce() idiom could use, so "replace, don't
  # merge" is the only sound semantic here).
  kafka_listeners_raw = coalesce(var.kafka_cr_overrides.listeners, [
    { name = "plain", port = 9092, type = "internal", tls = false, authentication = null }
  ])
  kafka_listeners = [
    for l in local.kafka_listeners_raw : {
      for k, v in l : k => v if v != null
    }
  ]

  # spec.kafka.template.pod's labels are the module's own fixed default,
  # never overridden here; podDisruptionBudget is additive on top since the
  # CR sets none by default (this repo's only other PDB is Flink's
  # JobManager, a native kubernetes_pod_disruption_budget_v1, unrelated to
  # this CR). Because template's other keys (pod.metadata.labels) must
  # survive untouched, this is a nested merge() at the one level that needs
  # it, not a flat merge() of the whole template object.
  kafka_template = merge(
    {
      pod = {
        metadata = {
          labels = {
            "living-stack"           = var.system
            "living-stack-component" = "streaming"
          }
        }
      }
    },
    var.kafka_cr_overrides.pod_disruption_budget != null ? {
      podDisruptionBudget = {
        maxUnavailable = var.kafka_cr_overrides.pod_disruption_budget.max_unavailable
      }
    } : {}
  )

  kafka_manifest = yamlencode({
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "Kafka"
    metadata = {
      name      = "kafka"
      namespace = var.namespace
      annotations = {
        "strimzi.io/node-pools" = "enabled"
        "strimzi.io/kraft"      = "enabled"
      }
    }
    spec = {
      kafka = {
        listeners = local.kafka_listeners
        config = {
          "offsets.topic.replication.factor"         = "1"
          "transaction.state.log.replication.factor" = "1"
          "transaction.state.log.min.isr"            = "1"
          "default.replication.factor"               = "1"
          "min.insync.replicas"                      = "1"
        }
        template = local.kafka_template
      }
      entityOperator = {
        template = {
          pod = {
            metadata = {
              labels = {
                "living-stack"           = var.system
                "living-stack-component" = "streaming"
              }
            }
          }
        }
        topicOperator = {}
        userOperator  = {}
      }
    }
  })

  # Both ternary branches are complete objects with the same attribute set
  # (type, size, deleteClaim), so OpenTofu's conditional-expression type
  # unification resolves to a real object type here. When the branches had
  # different attribute sets (persistent-claim's three keys vs ephemeral's
  # one), unification fell back to map(string) instead -- every attribute
  # widened to a single common type across both branches, so deleteClaim's
  # `true` came out the STRING "true", which Kubernetes rejects for a
  # boolean field. size/deleteClaim are meaningless on the ephemeral branch,
  # so they're null there and stripped by the for-expression below, leaving
  # ephemeral's rendered YAML exactly {type = "ephemeral"} as before.
  nodepool_storage_raw = var.nodepool_storage_type == "persistent-claim" ? {
    type        = "persistent-claim"
    size        = var.nodepool_storage_size
    deleteClaim = true
    } : {
    type        = "ephemeral"
    size        = null
    deleteClaim = null
  }

  nodepool_storage = {
    for k, v in local.nodepool_storage_raw : k => v if v != null
  }

  nodepool_manifest = yamlencode({
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaNodePool"
    metadata = {
      name      = "dual-role"
      namespace = var.namespace
      labels    = { "strimzi.io/cluster" = "kafka" }
    }
    spec = {
      replicas = var.nodepool_replicas
      roles    = ["controller", "broker"]
      storage  = local.nodepool_storage
      resources = {
        requests = { cpu = var.nodepool_cpu, memory = var.nodepool_memory }
        limits   = { cpu = var.nodepool_cpu, memory = var.nodepool_memory }
      }
    }
  })
}

# Debug copies under .rendered/, same convention as ../flink_sql_job's own
# local_file: not read by any resource here, just a human-readable artifact
# of what kubectl_manifest below actually applies.
resource "local_file" "kafka" {
  filename = "${path.root}/.rendered/streaming-kafka-${var.namespace}.yaml"
  content  = local.kafka_manifest
}

resource "local_file" "kafka_nodepool" {
  filename = "${path.root}/.rendered/streaming-kafka-nodepool-${var.namespace}.yaml"
  content  = local.nodepool_manifest
}

resource "kubectl_manifest" "kafka" {
  depends_on = [null_resource.wait_for_crds]

  yaml_body = local_file.kafka.content
  # false is the provider default (update in place), made explicit here: a
  # future change to nodepool_replicas or nodepool_storage_size becomes a
  # real `kubectl apply` patch against the live Kafka object instead of
  # tearing brokers down, matching how helm_release's own --wait upgrades
  # behave today.
  force_new = false

  timeouts {
    create = var.kafka_ready_timeout
    update = var.kafka_ready_timeout
  }

  # Strimzi's own published Ready condition on the Kafka CR, not a
  # hand-rolled poll: the same signal stack.sh's
  # `kubectl wait "kafka/kafka" ... --for=condition=Ready` relied on.
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

resource "kubectl_manifest" "kafka_nodepool" {
  depends_on = [null_resource.wait_for_crds]

  yaml_body = local_file.kafka_nodepool.content
  force_new = false
}

# Debug copy under .rendered/, one file per topic, same convention as
# local_file.kafka/local_file.kafka_nodepool above.
resource "local_file" "kafka_topic" {
  for_each = local.topics

  filename = "${path.root}/.rendered/streaming-kafka-topic-${var.namespace}-${each.value.resource_name}.yaml"
  content = yamlencode({
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaTopic"
    metadata = {
      name      = each.value.resource_name
      namespace = var.namespace
      labels    = { "strimzi.io/cluster" = "kafka" }
    }
    spec = {
      topicName  = each.value.topic_name
      partitions = each.value.partitions
      replicas   = 1
      config     = each.value.config
    }
  })
}

resource "kubectl_manifest" "kafka_topic" {
  for_each = local.topics

  # Topic finalizers need both the entity operator and live brokers. Preserve
  # both until the API confirms every KafkaTopic is absent, not just deleting.
  depends_on = [kubectl_manifest.kafka, kubectl_manifest.kafka_nodepool]

  wait           = true
  delete_cascade = "Background"

  yaml_body = local_file.kafka_topic[each.key].content
  force_new = false

  timeouts {
    create = "180s"
  }

  # Strimzi's own published Ready condition on the KafkaTopic CR, per topic,
  # replacing the old shell loop's `kubectl wait "kafkatopic/$name" ...`.
  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}
