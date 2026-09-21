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

# Stack for eh1-0043 (Coupled R3 + R6 OTel-Demo Task)
# Prometheus alert label mismatch + duplicate collector scrape inflation.
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
# seed carries the R6 collector_values override and the apply-time seed Job
# that configures the R3 Prometheus alert rule in ConfigMap prometheus.
module "seed" {
  source = "./seed"
}

locals {
  ns = "storefront"

  overrides = merge(
    module.seed.overrides,
    var.arm == "oracle" ? {} : {},
    var.arm == "violator" ? {} : {},
  )

  arm_objects = {
    oracle   = {}
    violator = {}
  }

  objects = merge(
    module.seed.objects,
    [for arm, o in local.arm_objects : o if arm == var.arm]...
  )

  # Solver may edit storefront (otel-collector, prometheus, alerts).
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

module "image_preload" {
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images = [
    "devops-bench/traffic-engine:1.0.0",
    "busybox:1.36",
    "bitnamilegacy/kubectl:1.29",
    "curlimages/curl:8.7.1",
    "python:3.11-slim",
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
  load_gen_vus    = 10
  scenario        = "baseline"

  collector_values       = lookup(local.overrides, "collector_values", {})
  scenario_json_override = lookup(local.overrides, "scenario_json_override", null)

  depends_on = [module.kafka_bus, module.image_preload]
}

resource "kubernetes_config_map_v1" "checkout_metrics_script" {
  metadata {
    name      = "checkout-metrics-script"
    namespace = local.ns
  }
  data = {
    "exporter.py" = <<-PY
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      START = time.time() - 300.0

      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              elapsed = max(0.0, time.time() - START)
              reqs = 1000.0 + elapsed * 2.0
              errs = 80.0 + elapsed * 0.16
              req_m = "checkout_" + "requests_total"
              err_m = "checkout_" + "errors_total"
              sn = "service_" + "name"
              if self.path.startswith("/legacy"):
                  body = (
                      f"# HELP {req_m} Total checkout requests\n"
                      f"# TYPE {req_m} counter\n"
                      f'{req_m}{{{sn}="checkout",service="checkout",tenant="storefront",pipeline="legacy"}} {reqs:.2f}\n'
                  ).encode("utf-8")
              else:
                  body = (
                      f"# HELP {req_m} Total checkout requests\n"
                      f"# TYPE {req_m} counter\n"
                      f'{req_m}{{{sn}="checkout",service="checkout",tenant="storefront",pipeline="primary"}} {reqs:.2f}\n'
                      f"# HELP {err_m} Total checkout errors\n"
                      f"# TYPE {err_m} counter\n"
                      f'{err_m}{{{sn}="checkout",service="checkout",tenant="storefront",pipeline="primary"}} {errs:.2f}\n'
                  ).encode("utf-8")
              self.send_response(200)
              self.send_header("Content-Type", "text/plain; version=0.0.4")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, format, *args):
              pass

      if __name__ == "__main__":
          ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PY
  }
  depends_on = [module.scene_otel_demo]
}

resource "kubectl_manifest" "checkout_metrics_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "checkout-metrics"
      namespace = local.ns
    }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "checkout-metrics" } }
      template = {
        metadata = { labels = { app = "checkout-metrics" } }
        spec = {
          volumes = [
            {
              name      = "script"
              configMap = { name = kubernetes_config_map_v1.checkout_metrics_script.metadata[0].name }
            }
          ]
          containers = [
            {
              name    = "exporter"
              image   = "python:3.11-slim"
              command = ["python3", "-u", "/app/exporter.py"]
              ports   = [{ containerPort = 8080 }]
              volumeMounts = [
                { name = "script", mountPath = "/app", readOnly = true }
              ]
            }
          ]
        }
      }
    }
  })
  server_side_apply = true
  wait_for_rollout  = true
  depends_on        = [kubernetes_config_map_v1.checkout_metrics_script]
}

resource "kubectl_manifest" "checkout_metrics_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "checkout-metrics"
      namespace = local.ns
    }
    spec = {
      type     = "ClusterIP"
      selector = { app = "checkout-metrics" }
      ports    = [{ name = "http", port = 8080, targetPort = 8080 }]
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.checkout_metrics_deployment]
}

# Baseline identity for the collector Deployment: identity_preserved
# compares its live uid and creation time against these baseline annotations.
locals {
  identity_baselines = {
    "storefront/Deployment/otel-collector" = { api_version = "apps/v1" }
    "storefront/Deployment/prometheus"     = { api_version = "apps/v1" }
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

# The seed's setup Job and its RBAC, applied before arm-specific Jobs.
resource "kubectl_manifest" "seed_rbac" {
  for_each = { for k, v in module.seed.objects : k => v if try(v.kind, "") != "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [module.scene_otel_demo, kubernetes_annotations.identity_baseline]
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

# Arm objects: RBAC first, then the arm's Job (repair or violator).
resource "kubectl_manifest" "objects_rbac" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") != "Job" && !contains(keys(module.seed.objects), k) }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [kubectl_manifest.seed]
}

resource "kubectl_manifest" "objects" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") == "Job" && !contains(keys(module.seed.objects), k) }

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

  depends_on = [kubectl_manifest.objects_rbac, kubectl_manifest.seed]
}

# Solver RBAC. Scoped to storefront namespace.
module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules     = []

  depends_on = [module.cluster, kubectl_manifest.seed, kubectl_manifest.objects]
}
