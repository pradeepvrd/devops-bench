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
  source = "../../modules/cluster/kind"

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
  source = "./seed"
}

locals {
  # Filtered comprehensions rather than the template's conditionals. A
  # conditional must have the same type on both branches, and an arm's objects
  # map is an object whose attribute types come from the manifests it carries:
  # this task's violator contributes a ServiceAccount, a Role, a RoleBinding and
  # a Job, four different shapes, which cannot unify with an empty object. The
  # static gate fails all three arms with "Inconsistent conditional result
  # types" before it ever reaches the cluster. A comprehension has no such
  # constraint and yields an empty map when the arm does not match. var.arm is
  # known at plan time, so this stays a plan-time decision.
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

  # Namespaces the solver may edit. A task lists its scene namespaces and any
  # namespace its seed creates. RBAC changes are task edits.
  # The solver operates the storefront. data-platform carries the bus and is
  # not this rota's to change; the verifier namespace is instrumentation.
  edit_namespaces = ["storefront"]
}

# The otel-demo scene's KafkaTopic is placed into the caller-provided
# kafka_namespace and needs an already-running external Strimzi cluster, so the
# bus comes up first. Sized for kind the same way eh1-0019 sizes it.
resource "kubernetes_namespace_v1" "data_platform" {
  metadata { name = "data-platform" }
}

module "kafka_bus" {
  source = "../../modules/living-stacks/streaming/tf/modules/kafka_strimzi"

  namespace             = kubernetes_namespace_v1.data_platform.metadata[0].name
  system                = "primary"
  kubeconfig            = var.kubeconfig_path
  create_cdc_topics     = false
  nodepool_replicas     = 1
  nodepool_storage_type = "ephemeral"
  nodepool_cpu          = "200m"
  nodepool_memory       = "768Mi"
  kafka_ready_timeout   = "420s"

  depends_on = [module.cluster]
}

module "image_preload" {
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images = [
    "devops-bench/traffic-engine:1.0.0",
    "busybox:1.36",
    "bitnamilegacy/kubectl:1.29",
    "curlimages/curl:8.7.1",
  ]
  depends_on = [module.cluster]
}

# Sourced from the repository config/pins.yaml names as living_stacks, which is
# also the registry the scene tag is validated against. Older tasks in this
# catalog point at a different fork; this one does not.
module "scene_otel_demo" {
  source = "../../modules/living-stacks/otel-demo/tf/scene"

  kubeconfig      = var.kubeconfig_path
  namespace       = "storefront"
  kafka_bootstrap = module.kafka_bus.kafka_bootstrap
  kafka_namespace = module.kafka_bus.namespace
  chart_version   = "0.41.0"

  # Not a taste decision, and not a way to make the fault easier to reach. At
  # the chart default of 10 virtual users the subject of this task emits about
  # 0.45 span-metric samples per minute, so a short observation window reads a
  # HEALTHY checkout as silent and the gate records a measurement artefact as a
  # solver miss. Measured at 60 virtual users it emits about 68 per minute --
  # 136 calls in two minutes -- which a two-minute window resolves without
  # ambiguity. load_gen_vus is a declared scene input, so this is configuration.
  load_gen_vus = 60

  scenario               = "baseline"
  scenario_json_override = lookup(local.overrides, "scenario_json_override", null)
  collector_values       = lookup(local.overrides, "collector_values", {})
  component_resources    = lookup(local.overrides, "component_resources", {})

  depends_on = [module.kafka_bus, module.image_preload]
}

resource "kubectl_manifest" "objects_rbac" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") != "Job" }

  depends_on = [module.scene_otel_demo]

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false
}

resource "kubectl_manifest" "objects" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") == "Job" }

  depends_on = [kubectl_manifest.objects_rbac]

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false
}

# Identity baselines (opt-in). A task declares "namespace/Kind/name" =>
# { api_version = "..." } for any object an identity_preserved check needs a
# pre-run baseline for; cluster-scoped objects use "_" as the namespace
# segment, matching local.objects' own key convention. Empty by default: a
# task that declares nothing gets no baseline resources here and plans
# byte-identical to a task written before this existed.
#
# data.kubernetes_resource would normally read the live object during
# `tofu plan`, which needs a cluster and would fail the static gate the same
# way kubernetes_manifest does. depends_on is what avoids that: OpenTofu
# defers a data source whose depends_on names something not yet created, so
# it reads at apply time instead, once the cluster and the object actually
# exist. Confirmed against a scratch config with an unresolved provider
# (no live cluster): without depends_on the plan fails immediately
# ("Failed to get RESTMapper client: cannot create discovery client: no
# client config"); with it, the data source plans as "will be read during
# apply (depends on a resource or a module with changes pending)".
#
# depends_on only accepts a literal list of resource/module references, not a
# local, so it is written out below rather than threaded through a variable.
# The template only has kubectl_manifest.objects at root scope; a task whose
# baselines name an object a scene module creates (the common case: an
# operator-managed CR or pod) must add that module to both depends_on lists
# below in its own main.tf.
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

  # Scoped to just these two keys (see the resource's own docs): existing
  # annotations an operator or another client manages are left alone.
  # force clears a one-time conflict if a prior baseline write raced it.
  field_manager = "stagehand-identity-baseline"
  force         = true
}

# Solver RBAC. Creates bench-system/bench-agent, the ServiceAccount the bench
# sandbox mints its token for. Applied after the scenes and the arm objects so
# the edit namespaces exist.
module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules     = []

  depends_on = [module.cluster, kubectl_manifest.objects]
}
