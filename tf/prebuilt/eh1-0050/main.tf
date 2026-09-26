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

terraform {
  required_version = ">= 1.8.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "= 0.11.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "= 2.4.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 2.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 2.17.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "= 3.3.1"
    }
  }
}

provider "kind" {}

locals {
  stream_namespace = "streaming"
  audit_namespace  = "enrichment-audit"

  kubectl_image = "bitnamilegacy/kubectl@sha256:d4397a782dcc1e9495c9632a3c7eef1c8b081af357261c5dc25c3c80c5e3649c"
  kafka_image   = "apache/kafka:3.9.0"

  preload_images = [
    local.kubectl_image,
    local.kafka_image,
  ]

  kafka_bootstrap = "kafka-kafka-bootstrap.${local.stream_namespace}.svc:9092"
}

module "cluster" {
  node_image = "kindest/node:v1.30.0@sha256:047357ac0cfea04663786a612ba1eaba9702bef25227a794b52890dd8bcd692e"
  source     = "../../modules/cluster/kind"

  cluster_name        = var.cluster_name
  project_id          = var.project_id
  location            = var.location
  kubeconfig_path     = var.kubeconfig_path
  node_count          = var.node_count
  disable_default_cni = var.disable_default_cni
}

module "image_preload" {
  source = "../../modules/living-stacks/platform/image_preload"

  cluster_name = module.cluster.cluster_name
  images       = local.preload_images
  depends_on   = [module.cluster]
}

provider "kubectl" {
  host                   = module.cluster.endpoint
  cluster_ca_certificate = module.cluster.cluster_ca_certificate
  client_certificate     = module.cluster.client_certificate
  client_key             = module.cluster.client_key
  load_config_file       = false
  lazy_load              = true
  apply_retry_count      = 5
}

provider "kubernetes" {
  host                   = module.cluster.endpoint
  cluster_ca_certificate = module.cluster.cluster_ca_certificate
  client_certificate     = module.cluster.client_certificate
  client_key             = module.cluster.client_key
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.endpoint
    cluster_ca_certificate = module.cluster.cluster_ca_certificate
    client_certificate     = module.cluster.client_certificate
    client_key             = module.cluster.client_key
  }
}

module "seed" {
  source = "./seed"
}

locals {
  overrides = merge(
    module.seed.overrides,
    { for k, v in {} : k => v if var.arm == "oracle" },
    { for k, v in {} : k => v if var.arm == "violator" },
  )

  objects = merge(
    module.seed.objects,
    { for k, v in {} : k => v if var.arm == "oracle" },
    { for k, v in {} : k => v if var.arm == "violator" },
  )

  edit_namespaces = [local.stream_namespace]
}

resource "kubernetes_namespace_v1" "streaming" {
  metadata {
    name = local.stream_namespace

    labels = {
      "living-stack"           = "primary"
      "living-stack-component" = "streaming"
    }
  }
}

module "kafka_bus" {
  source = "../../modules/living-stacks/streaming/tf/modules/kafka_strimzi"

  namespace             = kubernetes_namespace_v1.streaming.metadata[0].name
  system                = "primary"
  kubeconfig            = var.kubeconfig_path
  create_cdc_topics     = true
  nodepool_replicas     = 1
  nodepool_storage_type = "ephemeral"
  nodepool_cpu          = "1000m"
  nodepool_memory       = "2Gi"
  kafka_ready_timeout   = "420s"

  topic_config_overrides = merge(
    {
      cdc_public_orders    = { "retention.ms" = "18000000" }
      cdc_public_customers = { "cleanup.policy" = "compact" }
      orders_enriched      = { "retention.ms" = "86400000", "message.timestamp.type" = "LogAppendTime" }
      events_agg           = { "cleanup.policy" = "compact" }
    },
    lookup(local.overrides, "topic_config_overrides", {})
  )

  depends_on = [module.image_preload, kubernetes_namespace_v1.streaming]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true

  wait             = true
  wait_for_rollout = false

  dynamic "wait_for" {
    for_each = try(each.value.kind, "") == "Job" ? [1] : []
    content {
      condition {
        type   = "Complete"
        status = "True"
      }
    }
  }

  dynamic "wait_for" {
    for_each = contains(["streaming/Deployment/orders-enrichment", "streaming/Deployment/orders-rollup"], each.key) ? [1] : []
    content {
      condition {
        type   = "Available"
        status = "True"
      }
    }
  }

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [module.kafka_bus, kubernetes_job_v1.incident_seed, kubernetes_deployment_v1.enrichment_auditor]
}

locals {
  identity_baselines = {}
}

data "kubernetes_resource" "identity_baseline" {
  for_each = local.identity_baselines

  api_version = each.value.api_version
  kind        = split("/", each.key)[1]

  metadata {
    name      = split("/", each.key)[2]
    namespace = split("/", each.key)[0] == "_" ? null : split("/", each.key)[0]
  }

  depends_on = [kubectl_manifest.objects]
}

resource "kubernetes_annotations" "identity_baseline" {
  for_each = local.identity_baselines

  api_version = each.value.api_version
  kind        = split("/", each.key)[1]

  metadata {
    name      = split("/", each.key)[2]
    namespace = split("/", each.key)[0] == "_" ? null : split("/", each.key)[0]
  }

  annotations = {
    "devops-bench.io/original-uid"                = data.kubernetes_resource.identity_baseline[each.key].object.metadata.uid
    "devops-bench.io/original-creation-timestamp" = data.kubernetes_resource.identity_baseline[each.key].object.metadata.creationTimestamp
  }

  field_manager = "stagehand-identity-baseline"
  force         = true

  depends_on = [kubectl_manifest.objects]
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = false
  extra_rules = [
    { "api_groups" = ["kafka.strimzi.io"], "resources" = ["kafkatopics"], "verbs" = ["get", "list", "watch", "update", "patch"] },
    { "api_groups" = ["kafka.strimzi.io"], "resources" = ["kafkas", "kafkanodepools", "strimzipodsets"], "verbs" = ["get", "list", "watch"] },
  ]

  depends_on = [module.cluster, module.kafka_bus, kubectl_manifest.objects]
}
