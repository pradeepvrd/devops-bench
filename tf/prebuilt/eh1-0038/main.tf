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

# Arms. The seed carries the platform's logs-delivery policy (declaratively, through
# the scene's registered collector_values override) and the maintenance change that
# installed a failing default ingest pipeline on the log indices (an apply-time Job).
# The oracle and violator are apply-time Jobs acting on that world after the chain has
# formed: the reference repair (detach the failing pipeline), and the reflex (restart
# the collector), so both are proven from the state the solver is handed.
module "seed" {
  source = "./seed"
}

locals {
  ns = "storefront"

  overrides = merge(
    module.seed.overrides,
    { for k, v in {} : k => v if var.arm == "oracle" },
    { for k, v in {} : k => v if var.arm == "violator" },
  )
  arm_objects = {
    oracle   = {}
    violator = {}
  }
  objects = merge(
    {},
    [for arm, o in local.arm_objects : o if arm == var.arm]...
  )

  # The solver operates the storefront: the collector, its configuration, and the
  # telemetry backends that run beside it. The measurement namespace is instrumentation.
  edit_namespaces = [local.ns]
}

resource "kubernetes_namespace_v1" "data_platform" {
  metadata { name = "data-platform" }
  depends_on = [module.cluster]
}

# The order-flow bus the demo's checkout publishes to. One small ephemeral broker.
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

# The otel-demo scene's storefront-status prober runs the generator image from the
# private Artifact Registry repo, which a kind node cannot pull (anonymous 403). The
# first base control failed exactly so (ImagePullBackOff on a pool runner, 2026-09-18;
# local clusters on a host with registry credentials hid it). The platform module pulls
# on the host and imports into every node, after the cluster and before the scene, as
# its README requires; eh1-0036 wires it the same way. The Docker Hub images the task's
# Jobs and exporter use, and the session-activity feed's image (it drives the fault),
# are preloaded too, away from anonymous rate limits and pull failures.
module "image_preload" {
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images = [
    "devops-bench/traffic-engine:1.0.0",
    "busybox:1.36",
    "bitnamilegacy/kubectl:1.29",
    "ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.156.0",
  ]
  depends_on = [module.cluster]
}

module "scene_otel_demo" {
  source = "../../modules/living-stacks/otel-demo/tf/scene"

  kubeconfig      = var.kubeconfig_path
  namespace       = local.ns
  kafka_bootstrap = module.kafka_bus.kafka_bootstrap
  kafka_namespace = module.kafka_bus.namespace
  chart_version   = "0.41.0"
  load_gen_vus    = 60
  scenario        = "baseline"

  collector_values = lookup(local.overrides, "collector_values", {})

  depends_on = [module.kafka_bus, module.image_preload]
}

# The storefront's session-activity feed: customer activity events shipped to the
# collector as OTLP logs, about 500 records per second. It is the reason the platform
# runs the logs exporter under a never-drop policy (seed overrides). The demo's own
# services log only about 4 records per second (measured across 13 eh1-0021 attempts at
# the same 60 VUs), too little for a rejected-logs backlog ever to reach the collector's
# memory_limiter; this feed is the volume that makes it matter (measured locally with the
# pinned collector: a refusing limiter and traces gone from Jaeger, and a full drain
# about a minute after the reference repair). It is scene workload, present in every arm,
# and carries nothing about the fault. Its events are operational (route, timings,
# cache, experiment), with no user, device or location fields, so nothing in the logs
# the guard blocks argues that the guard belongs on them. Scaling it down does not
# repair anything: the backlog already held stays until OpenSearch accepts it.
locals {
  session_activity_event = "{\"event\":\"session.activity\",\"route\":\"/api/cart\",\"action\":\"add_item\",\"items\":3,\"status\":200,\"latency_ms\":184,\"upstream\":\"frontend-proxy:8080\",\"build\":\"2026.09.17-rc2\",\"region\":\"us-central1\",\"cache\":\"miss\",\"retries\":0,\"flags\":{\"checkout_v2\":\"on\",\"reco_model\":\"b\",\"search_v3\":\"off\"},\"bytes_in\":812,\"bytes_out\":5821,\"timings\":{\"dns_ms\":1,\"connect_ms\":2,\"tls_ms\":0,\"ttfb_ms\":151,\"render_ms\":27},\"cart_total_cents\":12940,\"currency\":\"USD\",\"experiment\":\"exp-2291-control\",\"queue\":\"checkout-default\",\"shard\":7,\"pool\":\"web-b\",\"note\":\"client-side event batch flushed on route change\"}"
}

resource "kubectl_manifest" "session_activity" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1", kind = "Deployment"
    metadata   = { name = "session-activity", namespace = local.ns, labels = { app = "session-activity" } }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "session-activity" } }
      template = {
        metadata = { labels = { app = "session-activity" } }
        spec = {
          containers = [{
            name  = "emitter"
            image = "ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.156.0"
            args = [
              "logs", "--otlp-endpoint", "otel-collector:4317", "--otlp-insecure",
              "--workers", "5", "--rate", "100", "--duration", "inf", "--allow-export-failures",
              "--service", "session-activity", "--body", local.session_activity_event,
            ]
            resources = {
              requests = { cpu = "50m", memory = "32Mi" }
              limits   = { memory = "128Mi" }
            }
          }]
        }
      }
    }
  })
  server_side_apply = true
  wait              = true
  wait_for_rollout  = true

  depends_on = [module.scene_otel_demo]
}

# Baseline identity for the collector Deployment: the annotations identity_preserved
# (collector-not-recreated) compares its live uid and creation time against. This is
# the template's identity_baselines mechanism; the Deployment is created by the scene
# module, so the read waits on that module (a built-in kind, so the data source can
# read it, unlike eh1-0036's CRD). It is stamped before the maintenance change and
# before any arm acts. Annotating the Deployment's metadata does not roll its Pods.
locals {
  identity_baselines = {
    "storefront/Deployment/otel-collector" = { api_version = "apps/v1" }
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

  depends_on = [module.scene_otel_demo]
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
}

# The seed's maintenance Job and its RBAC, applied before anything arm-specific. The
# RBAC applies first (in one for_each a Job can race its own permissions), and the Job
# is waited on to completion. startup-sync (status.tf) then holds the apply until the
# chain has formed, so the incident is in place before the attempt's clock starts.
resource "kubectl_manifest" "seed_rbac" {
  for_each = { for k, v in module.seed.objects : k => v if try(v.kind, "") != "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [module.scene_otel_demo, kubectl_manifest.status, kubectl_manifest.session_activity, kubernetes_annotations.identity_baseline]
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
    create = "2400s"
    update = "2400s"
  }

  depends_on = [kubectl_manifest.seed_rbac]
}

# Arm objects: RBAC first, then the arm's Job, once startup-sync (status.tf) has seen
# the incident form.
resource "kubectl_manifest" "objects_rbac" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") != "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [kubectl_manifest.startup_sync]
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
    create = "3000s"
    update = "3000s"
  }

  depends_on = [kubectl_manifest.objects_rbac]
}

# Solver RBAC. Edit rights in the storefront (the collector, its ConfigMap, the
# telemetry backends' workloads), pod exec for reaching the backends' HTTP APIs, and
# cluster-wide read.
module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules     = []

  depends_on = [module.cluster, kubectl_manifest.startup_sync, kubectl_manifest.objects]
}
