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

# The opentelemetry-demo helm chart itself. Unlike the streaming/cdc CRs,
# the chart is a real upstream helm release with no cross-release ownership
# problem once the RBAC/mode fixes in values-gke.yaml are in place, so
# helm_release with its own `wait` is the natural, cheapest mechanism here
# (docs/terraform-scene-layout.md section 2's helm_release precedent),
# replacing stack.sh's up_gke chain of `kubectl rollout status` calls in one
# step.
#
# values-common.yaml (lane-independent) and the rendered values-gke.yaml
# (this instance's NS/SYSTEM/KAFKA_* substitutions) are layered explicitly,
# same order stack.sh's helm invocation uses: `-f values-common.yaml -f
# <rendered values-gke.yaml>`, so values-gke.yaml's overrides win on any key
# both files set.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
  }
}

locals {
  kafka_host = split(":", var.kafka_bootstrap)[0]
  kafka_port = split(":", var.kafka_bootstrap)[1]
  release    = "otel-demo-${var.namespace}"
  collector_values = {
    for key, value in var.collector_values : key => value if value != null
  }
  component_resources = {
    for name, resources in var.component_resources : name => {
      resources = {
        for key, value in resources : key => {
          for resource, amount in value : resource => amount if amount != null
        } if value != null
      }
    }
  }
}

resource "helm_release" "otel_demo" {
  name             = local.release
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-demo"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false

  values = concat([
    file(var.values_common_path),
    templatefile("${path.module}/templates/values-gke.yaml.tftpl", {
      namespace       = var.namespace
      system          = var.system
      kafka_bootstrap = var.kafka_bootstrap
      kafka_host      = local.kafka_host
      kafka_port      = local.kafka_port
      kafka_topic     = var.kafka_topic
    })
    ], length(local.collector_values) == 0 ? [] : [yamlencode({
      opentelemetry-collector = local.collector_values
      })], length(local.component_resources) == 0 ? [] : [yamlencode({
      components = local.component_resources
  })])

  dynamic "set" {
    for_each = var.load_gen_vus != null ? [var.load_gen_vus] : []
    content {
      name  = "components.load-generator.env[0].value"
      value = set.value
      type  = "string"
    }
  }

  # Not part of values-gke.yaml, on by default (false, matching stack.sh's
  # unmodified helm invocation exactly). Confirmed live on a GKE Autopilot
  # cluster: the chart's default opentelemetry-collector.presets.hostMetrics
  # mounts a hostPath volume at "/" (hostfs), which Autopilot's Warden
  # admission policy rejects outright ("autogke-no-write-mode-hostpath"),
  # failing the whole release. stack.sh hits the exact same failure
  # unmodified on such a cluster; this is a pre-existing chart-defaults vs.
  # Autopilot incompatibility, not something the TF wrapping introduced.
  # Set true only when targeting an Autopilot-shaped cluster.
  dynamic "set" {
    for_each = var.disable_collector_host_metrics ? [true] : []
    content {
      name  = "opentelemetry-collector.presets.hostMetrics.enabled"
      value = "false"
    }
  }

  # helm's own --wait, matching stack.sh's `helm upgrade --install ...
  # --timeout 15m` plus its own subsequent per-deployment rollout waits:
  # helm --wait already blocks until every Deployment/StatefulSet/Job in the
  # release has the minimum number of ready replicas, superseding that
  # manual loop.
  wait    = true
  timeout = var.helm_timeout
}
