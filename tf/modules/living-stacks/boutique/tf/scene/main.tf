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

# Composes ../modules/onlineboutique into the shape boutique/stack.sh's
# `up gke` produces: the namespace, labeled/annotated the same way stack.sh's
# up_gke() does, then the chart itself. See ../modules/onlineboutique/main.tf's
# header comment for the render/patch/apply pipeline that stands in for
# ../../post-renderer.sh, and README.md's "Divergence from stack.sh" for what
# that pipeline does and does not reproduce.

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
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
}

locals {
  # Variable defaults cannot reference path.module, so the real defaults for
  # every source-file path this scene reads live here instead (mirrors
  # ../../../streaming/tf/scene's own pattern of inlining
  # `${path.module}/../foo` at the call site rather than as a variable
  # default).
  profile_json_path = coalesce(var.profile_json_path, "${path.module}/../../profiles/${var.profile}.json")
  values_path       = coalesce(var.values_path, "${path.module}/../../values.yaml")

  profile_json = var.profile_json_override != null ? var.profile_json_override : file(local.profile_json_path)
  profile_data = jsondecode(local.profile_json)
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "living-stack"           = var.system
      "living-stack-component" = "boutique"
    }
    annotations = {
      "living-stacks.boutique/profile" = var.profile
    }
  }
}

module "boutique" {
  source = "../modules/onlineboutique"

  namespace               = kubernetes_namespace_v1.this.metadata[0].name
  system                  = var.system
  release_name            = var.release_name
  chart_repository        = var.chart_repository
  chart_name              = var.chart_name
  chart_version           = var.chart_version
  values_path             = local.values_path
  loadgen_users           = local.profile_data.users
  loadgen_rate            = local.profile_data.rate
  rollout_timeout_seconds = var.rollout_timeout_seconds
  kubeconfig              = var.kubeconfig
  cart_database_endpoint  = var.service_endpoints.cart_database
}
