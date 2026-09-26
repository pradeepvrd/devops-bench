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

# Stack template (spec 5.3), extended for eh1-0076: prepared transactions a two-phase-commit
# coordinator left in doubt hold the shop's cleanup horizon.
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
  ledger_namespace   = "ledger"

  # distinct(): var.oracle_image is now the oltp-writer image, and importing the
  # same ref twice per node is wasted work on every apply.
  preload_images = distinct([
    "ghcr.io/cloudnative-pg/postgresql:18.6",
    "quay.io/debezium/server:3.6.1.Final",
    "devops-bench/oltp-writer:1.0.0",
    var.oracle_image,
  ])
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

# Baseline identity for the objects the policy says must survive. The
# identity_preserved verifier compares a resource's live uid and creation
# timestamp against these annotations; without them it fails every arm with
# "carries no baseline identity annotation", which is what the first controls
# run that got this far reported.
locals {
  identity_baselines = {
    "orders-db/Cluster/shop"                 = { api_version = "postgresql.cnpg.io/v1" }
    "orders-db/PersistentVolumeClaim/shop-1" = { api_version = "v1" }
  }
}

data "kubernetes_resource" "identity_baseline" {
  for_each = local.identity_baselines

  api_version = each.value.api_version
  kind        = split("/", each.key)[1]

  metadata {
    name      = split("/", each.key)[2]
    namespace = split("/", each.key)[0]
  }

  # connector_rollout re-applies Deployment/debezium-server, so the baseline is read
  # after it: server-side apply preserves the uid, but reading before the last writer
  # has finished would race the annotation against it.
  depends_on = [module.scene_cdc, kubernetes_job_v1.onboarding, kubectl_manifest.connector_rollout, kubernetes_job_v1.wait_twophase]
}

resource "kubernetes_annotations" "identity_baseline" {
  for_each = local.identity_baselines

  api_version = each.value.api_version
  kind        = split("/", each.key)[1]

  metadata {
    name      = split("/", each.key)[2]
    namespace = split("/", each.key)[0]
  }

  annotations = {
    "devops-bench.io/original-uid"                = data.kubernetes_resource.identity_baseline[each.key].object.metadata.uid
    "devops-bench.io/original-creation-timestamp" = data.kubernetes_resource.identity_baseline[each.key].object.metadata.creationTimestamp
  }

  field_manager = "stagehand-identity-baseline"
  force         = true
}

module "seed" {
  source = "./seed"
}

# The control arms act on the scene a solver would inherit, once the scene check has seen
# it form -- the coordinator back and waiting, the exporter holding its baseline -- so
# the exporter's first sample is the scene before the arm rather than after it.
# The arms add no objects of their own: each is a Job that acts through the databases.
locals {
  overrides       = module.seed.overrides
  objects         = module.seed.objects
  edit_namespaces = [local.source_namespace]
}

module "scene_cdc" {
  source = "../../modules/living-stacks/cdc/tf/scene"

  kubeconfig      = var.kubeconfig_path
  namespace       = local.source_namespace
  kafka_bootstrap = module.cdc_bus.kafka_bootstrap

  # Single instance on purpose. At the scene default of two, a standby exists and
  # promoting it is a plausible move during a storage incident -- which is
  # eh1-0034's fault, not this one. Removing the standby removes that path, so a
  # solver cannot stumble into a different task's incident and fail this one's
  # continuity objective for a reason this task never intended to test.
  instances            = 1
  oltp_writer_replicas = 1

  depends_on = [module.image_preload, module.cdc_bus]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true

  wait             = true
  wait_for_rollout = false

  depends_on = [module.scene_cdc, kubernetes_job_v1.onboarding, kubernetes_annotations.identity_baseline]
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = false
  extra_rules = [
    { api_groups = [""], resources = ["pods"], verbs = ["get", "list", "watch"] },
    { api_groups = [""], resources = ["pods/exec"], verbs = ["create"] },
    { api_groups = ["postgresql.cnpg.io"], resources = ["clusters", "clusters/status"], verbs = ["get", "list", "watch"] },
  ]

  depends_on = [
    module.cluster,
    module.scene_cdc,
    kubectl_manifest.objects,
    kubectl_manifest.connector_rollout,
    kubernetes_labels.solver_pod_security,
    kubernetes_job_v1.drain,
    kubectl_manifest.payments_recon_start,
    kubernetes_deployment_v1.status,
    kubernetes_job_v1.scene_check,
  ]
}
