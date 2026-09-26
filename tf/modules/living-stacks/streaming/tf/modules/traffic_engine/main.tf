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

resource "kubernetes_secret_v1" "traffic_engine_script" {
  metadata {
    name      = "traffic-engine-script"
    namespace = var.namespace
  }

  data = {
    "producer.py" = file(var.script_path)
  }
}

resource "kubernetes_secret_v1" "traffic_profile" {
  count = var.profile_as_configmap ? 0 : 1

  metadata {
    name      = "traffic-profile"
    namespace = var.namespace
    annotations = {
      "living-stacks.streaming/profile" = var.profile_name
    }
  }

  data = {
    "profile.json" = var.profile_json
  }
}

resource "kubernetes_config_map_v1" "traffic_profile" {
  count = var.profile_as_configmap ? 1 : 0

  metadata {
    name      = "traffic-profile"
    namespace = var.namespace
    annotations = {
      "living-stacks.streaming/profile" = var.profile_name
    }
  }

  data = {
    "profile.json" = var.profile_json
  }
}

resource "kubernetes_service_v1" "traffic_engine" {
  metadata {
    name      = "traffic-engine"
    namespace = var.namespace
    labels = {
      app = "traffic-engine"
    }
  }

  spec {
    selector = {
      app = "traffic-engine"
    }

    port {
      name        = "http-status"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_deployment_v1" "traffic_engine" {
  metadata {
    name      = "traffic-engine"
    namespace = var.namespace
    labels = {
      app = "traffic-engine"
    }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        app = "traffic-engine"
      }
    }

    template {
      metadata {
        labels = {
          app = "traffic-engine"
        }
        annotations = {
          "checksum/profile" = sha256(var.profile_json)
          "checksum/script"  = sha256(file(var.script_path))
        }
      }

      spec {
        enable_service_links = false
        service_account_name = var.service_account_name

        container {
          name  = "traffic-engine"
          image = var.image
          command = ["sh", "-c", <<-EOT
            set -e
            exec python /app/producer.py
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
            name  = "KAFKA_BOOTSTRAP"
            value = var.kafka_bootstrap
          }
          env {
            name  = "TOPIC"
            value = var.topic
          }
          env {
            name  = "PROFILE_PATH"
            value = "/profile/profile.json"
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
            secret_name = kubernetes_secret_v1.traffic_engine_script.metadata[0].name
          }
        }
        dynamic "volume" {
          for_each = var.profile_as_configmap ? [] : [1]
          content {
            name = "profile"
            secret {
              secret_name = kubernetes_secret_v1.traffic_profile[0].metadata[0].name
            }
          }
        }
        dynamic "volume" {
          for_each = var.profile_as_configmap ? [1] : []
          content {
            name = "profile"
            config_map {
              name = kubernetes_config_map_v1.traffic_profile[0].metadata[0].name
            }
          }
        }
      }
    }
  }

  wait_for_rollout = var.replicas > 0

  timeouts {
    create = "5m"
  }
}
