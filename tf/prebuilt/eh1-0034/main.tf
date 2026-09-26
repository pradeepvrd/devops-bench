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

# Stack template (spec 5.3), extended for eh1-0034 CDC HA switchover task.
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
    local = {
      source  = "hashicorp/local"
      version = "= 2.9.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "= 3.3.1"
    }
  }
}

provider "kind" {}

locals {
  source_namespace   = "orders-db"
  bus_namespace      = "cdc-bus"
  verifier_namespace = "cdc-verifier"

  preload_images = [
    "ghcr.io/cloudnative-pg/postgresql:18.6",
    "quay.io/debezium/server:3.6.1.Final",
    "devops-bench/oltp-writer:1.0.0",
  ]
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

  edit_namespaces = [local.source_namespace]
}

module "scene_cdc" {
  source = "../../modules/living-stacks/cdc/tf/scene"

  kubeconfig           = var.kubeconfig_path
  namespace            = local.source_namespace
  kafka_bootstrap      = module.cdc_bus.kafka_bootstrap
  oltp_writer_replicas = 1

  depends_on = [module.image_preload, module.cdc_bus]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true

  wait             = true
  wait_for_rollout = false

  depends_on = [module.scene_cdc, kubernetes_job_v1.onboarding]
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = false
  extra_rules = [
    { api_groups = [""], resources = ["pods"], verbs = ["get", "list", "watch"] },
    { api_groups = [""], resources = ["pods/exec"], verbs = ["create"] },
    { api_groups = ["postgresql.cnpg.io"], resources = ["clusters", "clusters/status"], verbs = ["get", "list", "watch", "update", "patch"] },
  ]

  depends_on = [
    module.cluster,
    module.scene_cdc,
    kubectl_manifest.objects,
    kubectl_manifest.connector_rollout,
    kubernetes_deployment_v1.slot_auditor,
    kubernetes_labels.solver_pod_security,
  ]
}
