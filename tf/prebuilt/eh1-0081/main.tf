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
  source          = "./seed"
  audit_namespace = local.audit_ns
  runner_image    = var.kafka_image
}

locals {
  ns       = "streaming"
  sf_ns    = "storefront"
  audit_ns = "kafka-audit"

  # No scene overrides: the scene's own enrichment_events_sql_path input carries the one
  # change (see module.scene_streaming).
  overrides = {}

  arm_objects = {
    oracle   = {}
    violator = {}
  }
  objects = merge(
    {},
    [for arm, o in local.arm_objects : o if arm == var.arm]...
  )

  edit_namespaces = [local.ns, local.sf_ns]
}

module "image_preload" {
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images = [
    "docker.io/library/flink:1.20",
    "devops-bench/traffic-engine:1.0.0",
    var.kafka_image,
  ]
  depends_on = [module.cluster]
}

# The streaming scene with one change of its own: enrichment-events reads events.raw
# read_committed (CHG-6180) and carries event_id/user_id into events.product-enriched.
module "scene_streaming" {
  source = "../../modules/living-stacks/streaming/tf/scene"

  kubeconfig                 = var.kubeconfig_path
  namespace                  = local.ns
  enrichment_events_sql_path = "${path.module}/files/enrichment-events.sql"
  depends_on                 = [module.image_preload]
}

resource "kubectl_manifest" "seed_rbac" {
  for_each = { for k, v in module.seed.objects : k => v if try(v.kind, "") != "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [kubectl_manifest.workloads, kubectl_manifest.audit]
}

resource "kubectl_manifest" "seed" {
  for_each = { for k, v in module.seed.objects : k => v if try(v.kind, "") == "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  wait_for {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "3000s"
    update = "3000s"
  }

  depends_on = [kubectl_manifest.seed_rbac]
}

resource "kubectl_manifest" "objects_rbac" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") != "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [kubectl_manifest.seed]
}

resource "kubectl_manifest" "objects" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") == "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  wait_for {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "2400s"
    update = "2400s"
  }

  depends_on = [kubectl_manifest.objects_rbac]
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = false
  extra_rules     = []

  depends_on = [module.cluster, kubectl_manifest.seed, kubectl_manifest.objects]
}
