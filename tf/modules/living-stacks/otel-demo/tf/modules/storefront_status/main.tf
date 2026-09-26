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

resource "kubernetes_secret_v1" "storefront_status_script" {
  metadata {
    name      = "storefront-status-script"
    namespace = var.namespace
  }

  data = {
    "storefront_status.py" = file(var.script_path)
  }
}

resource "kubernetes_service_v1" "storefront_status" {
  metadata {
    name      = "storefront-status"
    namespace = var.namespace
    labels = {
      app                      = "storefront-status"
      "living-stack"           = var.system
      "living-stack-component" = "storefront"
    }
  }

  spec {
    selector = {
      app = "storefront-status"
    }

    port {
      name        = "http-status"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment_v1" "storefront_status" {
  metadata {
    name      = "storefront-status"
    namespace = var.namespace
    labels = {
      app                      = "storefront-status"
      "living-stack"           = var.system
      "living-stack-component" = "storefront"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "storefront-status"
      }
    }

    template {
      metadata {
        labels = {
          app                      = "storefront-status"
          "living-stack"           = var.system
          "living-stack-component" = "storefront"
        }
        annotations = {
          "checksum/script" = sha256(file(var.script_path))
        }
      }

      spec {
        enable_service_links = false

        container {
          name  = "storefront-status"
          image = var.image
          command = ["sh", "-c", <<-EOT
            set -e
            exec python /app/storefront_status.py
          EOT
          ]

          port {
            name           = "http-status"
            container_port = 8080
            protocol       = "TCP"
          }

          env {
            name  = "NAMESPACE"
            value = var.namespace
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          volume_mount {
            name       = "script"
            mount_path = "/app"
          }
        }

        volume {
          name = "script"
          secret {
            secret_name = kubernetes_secret_v1.storefront_status_script.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_rollout = true

  timeouts {
    create = "5m"
  }
}
