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

# Stack definition for eh1-0049: streaming + platform/keda coupled task (NW-3 / Sec 5.1).
#
# Provider pins are exact. helm and kubernetes stay on 2.x because every
# living-stacks scene pins hashicorp/helm "~> 2.15.0" and was written against
# kubernetes 2.x. kind and null match the bench's own prebuilt pins.
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

# The kind module is sourced from the bench fork by git at the pinned sha.
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

# Arms. seed/, repair/, violator/ are modules with two outputs each.
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

  # Solver may edit the streaming namespace where order-indexer and governance policies live.
  edit_namespaces = ["streaming"]
}

module "image_preload" {
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images = [
    "docker.io/library/flink:1.20",
    "registry.k8s.io/kubectl:v1.31.5",
    "devops-bench/traffic-engine:1.0.0",
    "python:3.11-slim",
  ]
  depends_on = [module.cluster]
}

# The pinned streaming scene: Strimzi Kafka, Flink platform, and traffic generator
module "scene_streaming" {
  source                = "../../modules/living-stacks/streaming/tf/scene"
  kubeconfig            = var.kubeconfig_path
  namespace             = "streaming"
  profile_json_override = lookup(local.overrides, "profile_json_override", null)
  kafka_cr_overrides    = lookup(lookup(local.overrides, "streaming", {}), "kafka_cr_overrides", {})
  depends_on            = [module.cluster, module.image_preload]
}

# The KEDA platform module: operator, metrics server, and autoscaling CRDs
module "keda" {
  source             = "../../modules/living-stacks/platform/keda"
  kubeconfig         = var.kubeconfig_path
  keda_namespace     = "keda"
  create_namespace   = true
  install_operator   = true
  install_crds       = true
  keda_chart_version = "2.16.1"
  depends_on         = [module.cluster, module.image_preload]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [module.scene_streaming, module.keda]
}

# Baseline identity for governance policies and deployment: identity_preserved
# compares live uid and creationTimestamp against these baseline annotations.
locals {
  identity_baselines = {
    "streaming/ResourceQuota/streaming-quota"     = { api_version = "v1" }
    "streaming/LimitRange/streaming-limit-range"   = { api_version = "v1" }
    "streaming/Deployment/order-indexer"          = { api_version = "apps/v1" }
  }
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

# Solver RBAC: scoped to streaming namespace with permissions for KEDA autoscalers.
module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules = [
    {
      api_groups = ["keda.sh"]
      resources  = ["scaledobjects", "scaledobjects/status", "scaledobjects/scale", "triggerauthentications"]
      verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    }
  ]

  depends_on = [module.cluster, module.scene_streaming, kubectl_manifest.objects]
}
