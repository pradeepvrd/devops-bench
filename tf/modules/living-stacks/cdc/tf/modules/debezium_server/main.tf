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

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.0"
    }
  }
}

resource "kubernetes_config_map_v1" "debezium_config" {
  metadata {
    name      = "debezium-server-config"
    namespace = var.namespace
  }

  data = {
    "application.properties" = var.application_properties
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_deployment_v1" "debezium_server" {
  metadata {
    name      = "debezium-server"
    namespace = var.namespace
    labels = {
      app                      = "debezium-server"
      "living-stack"           = var.system
      "living-stack-component" = "orders-db"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "debezium-server"
      }
    }

    template {
      metadata {
        labels = {
          app                      = "debezium-server"
          "living-stack"           = var.system
          "living-stack-component" = "orders-db"
        }
      }

      spec {
        enable_service_links = false

        container {
          name  = "debezium-server"
          image = var.image

          env {
            name = "DEBEZIUM_DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = var.db_password_secret_name
                key  = "password"
              }
            }
          }

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "config"
            mount_path = "/debezium/config"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.debezium_config.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations,
      spec[0].template[0].spec[0].container[0].env,
    ]
  }

  # Native fit per docs/terraform-scene-layout.md section 4: the kubernetes
  # provider's own rollout wait (default true), replacing stack.sh's
  # `kubectl rollout status deployment/debezium-server`.
  wait_for_rollout = true

  timeouts {
    create = "10m"
  }
}
