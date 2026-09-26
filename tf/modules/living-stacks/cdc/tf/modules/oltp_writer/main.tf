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

resource "kubernetes_secret_v1" "oltp_writer_script" {
  metadata {
    name      = "oltp-writer-script"
    namespace = var.namespace
  }

  data = {
    "oltp_writer.py" = file(var.script_path)
  }
}

resource "kubernetes_secret_v1" "oltp_writer_profile" {
  metadata {
    name      = "oltp-writer-profile"
    namespace = var.namespace
    annotations = {
      "living-stacks.cdc/profile" = var.profile_name
    }
  }

  data = {
    "profile.json" = var.profile_json
  }
}

resource "kubernetes_service_v1" "oltp_writer" {
  metadata {
    name      = "oltp-writer"
    namespace = var.namespace
    labels = {
      app                      = "oltp-writer"
      "living-stack"           = var.system
      "living-stack-component" = "orders-db"
    }
  }

  spec {
    selector = {
      app = "oltp-writer"
    }

    port {
      name        = "http-status"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment_v1" "oltp_writer" {
  metadata {
    name      = "oltp-writer"
    namespace = var.namespace
    labels = {
      app                      = "oltp-writer"
      "living-stack"           = var.system
      "living-stack-component" = "orders-db"
    }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        app = "oltp-writer"
      }
    }

    template {
      metadata {
        labels = {
          app                      = "oltp-writer"
          "living-stack"           = var.system
          "living-stack-component" = "orders-db"
        }
        annotations = {
          "checksum/profile" = sha256(var.profile_json)
          "checksum/script"  = sha256(file(var.script_path))
        }
      }

      spec {
        enable_service_links = false

        container {
          name  = "oltp-writer"
          image = var.image
          command = ["sh", "-c", <<-EOT
            set -e
            exec python /app/oltp_writer.py
          EOT
          ]

          port {
            name           = "http-status"
            container_port = 8080
            protocol       = "TCP"
          }

          env {
            name  = "SEED"
            value = "42"
          }
          env {
            name  = "PROFILE_PATH"
            value = "/profile/profile.json"
          }
          env {
            name  = "PGHOST"
            value = var.pg_service
          }
          env {
            name  = "PGPORT"
            value = "5432"
          }
          env {
            name  = "PGDATABASE"
            value = "shop"
          }
          env {
            name  = "PGUSER"
            value = "app"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = var.app_secret_name
                key  = "password"
              }
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "script"
            mount_path = "/app"
          }
          volume_mount {
            name       = "profile"
            mount_path = "/profile"
          }
        }

        volume {
          name = "script"
          secret {
            secret_name = kubernetes_secret_v1.oltp_writer_script.metadata[0].name
          }
        }
        volume {
          name = "profile"
          secret {
            secret_name = kubernetes_secret_v1.oltp_writer_profile.metadata[0].name
          }
        }
      }
    }
  }

  # Native fit per docs/terraform-scene-layout.md section 4: the kubernetes
  # provider's own rollout wait (default true), replacing stack.sh's
  # `kubectl rollout status deployment/oltp-writer`.
  wait_for_rollout = true

  timeouts {
    create = "10m"
  }
}
