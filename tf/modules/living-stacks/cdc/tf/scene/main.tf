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

# Composes cnpg_postgres + debezium_server + oltp_writer into the exact
# shape cdc/stack.sh's `up gke` produces: same namespace/label conventions,
# same cdc-debezium-credentials secret, same derived Debezium topic names.
# KafkaTopic CRs are deliberately not created here; see README.md.

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
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }
}

locals {
  # Mirrors stack.sh's compute_derived_vars().
  topic_dot             = var.topic_prefix != "" ? "${var.topic_prefix}." : ""
  debezium_topic_prefix = "${local.topic_dot}cdc"
  offsets_topic         = "${local.topic_dot}cdc-offsets"
  schema_history_topic  = "${local.topic_dot}cdc-schema-history"
  debezium_secret_name  = "cdc-debezium-credentials"
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "living-stack"           = var.system
      "living-stack-component" = "orders-db"
    }
  }
}

# Replaces stack.sh's ensure_debezium_secret(): TF's own "create once,
# converge on diff" semantics stand in for that function's
# create-if-missing check.
resource "random_password" "debezium" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "cdc_debezium_credentials" {
  metadata {
    name      = local.debezium_secret_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  type = "kubernetes.io/basic-auth"

  data = {
    username = "debezium"
    password = random_password.debezium.result
  }
}

module "cnpg_postgres" {
  source = "../modules/cnpg_postgres"

  namespace                     = kubernetes_namespace_v1.this.metadata[0].name
  system                        = var.system
  install_operator              = var.install_operator
  cnpg_namespace                = var.cnpg_namespace
  cnpg_chart_version            = var.cnpg_chart_version
  instances                     = var.instances
  postgres_image                = var.postgres_image
  debezium_password_secret_name = kubernetes_secret_v1.cdc_debezium_credentials.metadata[0].name
  kubeconfig                    = var.kubeconfig

  depends_on = [kubernetes_secret_v1.cdc_debezium_credentials]
}

module "debezium_server" {
  source = "../modules/debezium_server"

  namespace               = kubernetes_namespace_v1.this.metadata[0].name
  system                  = var.system
  db_password_secret_name = kubernetes_secret_v1.cdc_debezium_credentials.metadata[0].name
  image                   = var.debezium_image
  application_properties = templatefile("${path.module}/../modules/debezium_server/templates/application.properties.tftpl", {
    kafka_bootstrap       = var.kafka_bootstrap
    debezium_topic_prefix = local.debezium_topic_prefix
    offsets_topic         = local.offsets_topic
    schema_history_topic  = local.schema_history_topic
  })

  depends_on = [module.cnpg_postgres]
}

module "oltp_writer" {
  source = "../modules/oltp_writer"

  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  system          = var.system
  script_path     = "${path.module}/../../oltp_writer.py"
  profile_json    = coalesce(var.oltp_writer_profile_override, file("${path.module}/../../profiles/${var.profile}.json"))
  profile_name    = var.profile
  pg_service      = module.cnpg_postgres.primary_service
  app_secret_name = module.cnpg_postgres.app_secret_name
  image           = var.oltp_writer_image
  replicas        = var.oltp_writer_replicas

  depends_on = [module.cnpg_postgres]
}
