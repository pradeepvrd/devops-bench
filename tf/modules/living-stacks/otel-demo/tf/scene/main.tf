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

# Composes order_flow_topic + shop_chart + flagd_scenario into the exact
# shape otel-demo/stack.sh's `up gke` produces: same namespace/label
# conventions, same order-flow KafkaTopic CR into $KAFKA_NS, same layered
# values-common.yaml/values-gke.yaml, same baseline-scenario apply as the
# last bring-up step.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}

locals {
  # Mirrors stack.sh's compute_derived_vars().
  topic_dot           = var.topic_prefix != "" ? "${var.topic_prefix}." : ""
  kafka_topic         = "${local.topic_dot}orders"
  topic_resource_name = "otel-demo-orders-${var.namespace}"
  scenario_json       = coalesce(var.scenario_json_override, file("${path.module}/../../scenarios/${var.scenario}.json"))
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "living-stack"           = var.system
      "living-stack-component" = "storefront"
    }
  }
}

module "order_flow_topic" {
  source = "../modules/order_flow_topic"

  kafka_namespace = var.kafka_namespace
  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  resource_name   = local.topic_resource_name
  system          = var.system
  topic_name      = local.kafka_topic
  kubeconfig      = var.kubeconfig
}

module "shop_chart" {
  source = "../modules/shop_chart"

  namespace                      = kubernetes_namespace_v1.this.metadata[0].name
  system                         = var.system
  kafka_bootstrap                = var.kafka_bootstrap
  kafka_topic                    = local.kafka_topic
  values_common_path             = "${path.module}/../../values-common.yaml"
  chart_version                  = var.chart_version
  load_gen_vus                   = var.load_gen_vus
  helm_timeout                   = var.helm_timeout
  disable_collector_host_metrics = var.disable_collector_host_metrics
  collector_values               = var.collector_values
  component_resources            = var.component_resources

  depends_on = [module.order_flow_topic]
}

module "flagd_scenario" {
  source = "../modules/flagd_scenario"

  namespace     = kubernetes_namespace_v1.this.metadata[0].name
  scenario_name = var.scenario
  scenario_json = local.scenario_json
  kubeconfig    = var.kubeconfig

  depends_on = [module.shop_chart]
}

module "storefront_status" {
  source = "../modules/storefront_status"

  namespace   = kubernetes_namespace_v1.this.metadata[0].name
  system      = var.system
  script_path = "${path.module}/../../base/storefront_status.py"

  depends_on = [module.flagd_scenario]
}
