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

# Stack template (spec 5.3), extended for this task's CDC scene, following the
# pattern eh1-0016 already uses for scene-backed tasks: the skeleton's
# provider/cluster/module shape, plus this task's own satellite resources
# (cdc-bus.tf, connector.tf, onboarding.tf, oracle.tf).
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

  # Public images a kind node pulls itself, plus the private Artifact Registry
  # images this render's pods need.
  preload_images = [
    "ghcr.io/cloudnative-pg/postgresql:18.6",
    "quay.io/debezium/server:3.6.1.Final",
    "devops-bench/oltp-writer:1.0.0",
    "curlimages/curl:8.11.1",
    var.oracle_image,
  ]
}

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

# kind nodes cannot authenticate to the private Artifact Registry repo the
# task-owned oracle image lives in, so it is pulled on the host and pushed
# into the node's containerd before the oracle Pod can start.
module "image_preload" {
  source = "../../modules/living-stacks/platform/image_preload"

  cluster_name = module.cluster.cluster_name
  images       = local.preload_images
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

# Arms. seed/ stays the empty template: the fault is the as-onboarded database
# state itself (onboarding.sql), which is common to every arm and is not an
# arm-conditional patch of a scene-owned object the way eh1-0016's single wrong
# property is. repair/ and violator/ are real: each declares the Kubernetes Job
# and ConfigMap-patch resources its own action needs directly, rather than the
# objects-map pattern, because both are sequential imperative actions (scale,
# drop, patch, scale back) that a merged manifest map cannot express. Both are
# always instantiated and gate their own resources on var.enabled, because a
# nested module cannot see the root's var.arm or its sibling resources
# directly.
module "seed" {
  source = "./seed"
}

locals {
  # A for expression, not a ternary: see eh1-0016/eh1-0015's own note on why a
  # ternary does not unify once an arm emits a different object shape.
  overrides = merge(
    module.seed.overrides,
    { for k, v in {} : k => v if var.arm == "oracle" },
    { for k, v in {} : k => v if var.arm == "violator" },
  )

  # Always empty in this task: repair and violator both declare their action
  # as real resources inside their own modules (see above) rather than as
  # objects-map entries, so nothing is ever merged in here. The map is kept
  # so this stack's outputs.tf matches the template contract.
  objects = merge(
    module.seed.objects,
    { for k, v in {} : k => v if var.arm == "oracle" },
    { for k, v in {} : k => v if var.arm == "violator" },
  )

  # Namespaces the solver may edit. cdc-bus stays read-only, granted
  # explicitly and narrowly in solver_access.tf (kafka.strimzi.io objects,
  # pods/logs, no Secrets), and cdc-verifier gets no grant at all, so the
  # verifier's own baseline cannot be reached from the solver's credential.
  edit_namespaces = [local.source_namespace]
}

# The pinned cdc scene, at the onix-net fork's sha. Its own default orders
# table and publication are not this task's fault as bootstrapped; onboarding.tf
# migrates the schema and the publication membership immediately afterward
# (see onboarding.sql for why the scene's own bootstrap SQL cannot express a
# partitioned orders table directly). oltp_writer_replicas stays 1: unlike
# eh1-0016, this task needs a live writer producing the "orders keep being
# placed, updates to older orders keep arriving" traffic the ticket describes,
# not just the acceptance challenge's own bounded writes.
module "scene_cdc" {
  source = "../../modules/living-stacks/cdc/tf/scene"

  kubeconfig            = var.kubeconfig_path
  namespace             = local.source_namespace
  kafka_bootstrap        = module.cdc_bus.kafka_bootstrap
  oltp_writer_replicas   = 1

  depends_on = [module.image_preload, module.cdc_bus]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true

  wait             = true
  wait_for_rollout = false

  depends_on = [module.scene_cdc, kubernetes_job_v1.onboarding, kubernetes_pod_v1.oracle]
}

# Solver RBAC. Creates bench-system/bench-agent, the ServiceAccount the bench
# sandbox mints its token for. Applied after the scene and this task's own
# objects so the edit namespace and its Pods exist. extra_rules is rendered
# into every per-namespace Role (module.bench_agent's own contract) and never
# into anything cluster-scoped, and local.edit_namespaces is exactly
# [orders-db], so the pods/pods-exec grant below lands in orders-db only, not
# cluster-wide. Beyond eh1-0016's grant, this task adds pods get/list and
# pods/exec create, scoped by that same mechanism to the CNPG primary the
# solver actually needs to reach: altering a publication and writing the
# debezium_signal table both require a session as the local postgres
# superuser, and running psql on the primary Pod through kubectl exec is the
# realistic DBA path to that session (the alternative -- exposing a superuser
# credential as a Secret the solver can read directly -- is a wider grant than
# exec into one already-running, already-admission-controlled Pod).
# cluster_read stays false: solver_access.tf grants the narrow, per-namespace
# read this task actually needs (cdc-bus) and a namespace-discovery
# ClusterRole, the same pattern eh1-0017 uses, so cdc-verifier is never
# reachable through a cluster-wide view binding.
module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = false
  extra_rules = [
    { api_groups = [""], resources = ["pods"], verbs = ["get", "list"] },
    { api_groups = [""], resources = ["pods/exec"], verbs = ["create"] },
  ]

  depends_on = [
    module.cluster,
    module.scene_cdc,
    kubectl_manifest.objects,
    kubectl_manifest.connector_rollout,
    kubernetes_labels.solver_pod_security,
  ]
}
