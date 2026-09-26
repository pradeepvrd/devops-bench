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

# Stack template (spec 5.3). Every task starts from this skeleton.
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

# The kind module is sourced from the bench fork by git at the pinned sha,
# never via the dispatch module tf/modules/cluster, whose GKE branch brings the
# google provider into every init.
module "cluster" {
  # Scoped sandbox admission policies require Kubernetes 1.30+.
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
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images       = ["ghcr.io/cloudnative-pg/postgresql:18.6", "quay.io/debezium/server:3.6.1.Final", "devops-bench/oltp-writer:1.0.0"]
  depends_on   = [module.cluster]
}

# Providers are configured from the cluster module's outputs, never from a
# kubeconfig file, so they depend on the cluster and are configured after it
# exists during apply. lazy_load lets the kubectl provider plan while host and
# certs are still unknown; kubernetes and helm defer on their own.
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

# Arms. seed/, repair/, violator/ are modules with two outputs each. They are
# composed by precedence, not sequence: the same object exists once per arm
# with the content that arm calls for. merge() is shallow at the objects key,
# so a repair or violator entry must be the complete object, not a patch.
module "seed" {
  source = "./seed"
}

locals {
  overrides = merge(
    module.seed.overrides,
    var.arm == "oracle" ? {} : {},
    var.arm == "violator" ? {} : {},
  )

  objects = merge(
    module.seed.objects,
    var.arm == "oracle" ? {} : {},
    var.arm == "violator" ? {} : {},
  )

  # Namespaces the solver may edit. A task lists its scene namespaces and any
  # namespace its seed creates. RBAC changes are task edits.
  edit_namespaces = ["orders-db"]
}

# S-005 (imported from pipelines, lineage.imported_from): the cdc scene, with
# the fault and the fix expressed entirely through its two registered override
# keys (living-stacks scenes.yaml at the pinned sha).
module "scene_cdc" {
  source = "../../modules/living-stacks/cdc/tf/scene"

  kubeconfig                   = var.kubeconfig_path
  namespace                    = "orders-db"
  kafka_bootstrap              = module.cdc_bus.kafka_bootstrap
  oltp_writer_replicas         = lookup(local.overrides, "oltp_writer_replicas", 1)
  oltp_writer_profile_override = lookup(local.overrides, "oltp_writer_profile_override", null)
  depends_on                   = [module.image_preload, module.cdc_bus]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true

  # wait is the delete-time wait. wait_for_rollout would block apply on a
  # seeded fault that never rolls out, so it is off for arm objects.
  wait             = true
  wait_for_rollout = false
}

# Solver RBAC. Creates bench-system/bench-agent, the ServiceAccount the bench
# sandbox mints its token for. Applied after the scenes and the arm objects so
# the edit namespaces exist.
module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules     = [{ "api_groups" = ["postgresql.cnpg.io"], "resources" = ["clusters"], "verbs" = ["get", "list", "watch", "patch", "update"] }, { "api_groups" = ["kafka.strimzi.io"], "resources" = ["kafkas", "kafkatopics", "kafkanodepools", "strimzipodsets"], "verbs" = ["get", "list", "watch"] }]

  depends_on = [module.cluster, module.scene_cdc, kubectl_manifest.objects]
}
