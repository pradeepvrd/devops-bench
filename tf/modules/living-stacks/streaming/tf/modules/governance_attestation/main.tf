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

# Per-topic retention governance attestation: a CronJob that reads each
# configured topic's *effective* (broker-side) retention.ms and writes a
# pass/fail verdict to a ConfigMap, so a check can read a real symptom
# surface instead of the harness assuming what a nightly attestation would
# have sampled.
#
# Reads effective config by exec-ing into a live broker pod and running that
# pod's own bundled kafka-configs.sh (see templates/attest.sh), never the
# KafkaTopic CR's spec: the Topic Operator owns and reconciles the CR, and a
# topic-scoped override can outrank the broker/cluster-wide defaults every
# other panel reads (factory-303/catalog/tasks/S-020/story.yaml's chain).
#
# Unlike ../kafka_strimzi's kafka.strimzi.io/v1 objects, CronJob is a plain
# native Kubernetes kind with full provider support, so this module uses
# kubernetes_cron_job_v1 directly rather than the null_resource + kubectl
# workaround the CRD-backed modules in this codebase need.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.18.0" # kubernetes_cron_job_v1
    }
  }
}

locals {
  policy_env = join(",", [for topic, retention_ms in var.topic_retention_policy : "${topic}=${retention_ms}"])
}

resource "kubernetes_service_account_v1" "attestation" {
  metadata {
    name      = "governance-attestation"
    namespace = var.namespace
  }
}

resource "kubernetes_role_v1" "attestation" {
  metadata {
    name      = "governance-attestation"
    namespace = var.namespace
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }

  # kafka-configs.sh --describe runs inside the broker pod's own container,
  # not against the bootstrap Service, so the attestation needs create on
  # the pods/exec subresource rather than any Kafka-side ACL.
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "create", "update", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "attestation" {
  metadata {
    name      = "governance-attestation"
    namespace = var.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.attestation.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.attestation.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_config_map_v1" "attestation_script" {
  metadata {
    name      = "governance-attestation-script"
    namespace = var.namespace
  }

  data = {
    "attest.sh" = file("${path.module}/templates/attest.sh")
  }
}

resource "kubernetes_cron_job_v1" "attestation" {
  metadata {
    name      = "governance-attestation"
    namespace = var.namespace
  }

  spec {
    schedule                      = var.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    suspend                       = var.suspend

    job_template {
      metadata {}

      spec {
        backoff_limit = 0

        template {
          metadata {}

          spec {
            service_account_name = kubernetes_service_account_v1.attestation.metadata[0].name
            restart_policy       = "Never"

            container {
              name    = "attest"
              image   = var.attestation_image
              command = ["/bin/sh", "/scripts/attest.sh"]

              env {
                name  = "NAMESPACE"
                value = var.namespace
              }
              env {
                name  = "KAFKA_CLUSTER_NAME"
                value = var.kafka_cluster_name
              }
              env {
                name  = "BROKER_POOL_LABEL"
                value = var.broker_pool_name
              }
              env {
                name  = "TOPIC_RETENTION_POLICY"
                value = local.policy_env
              }
              env {
                name  = "RESULT_CONFIGMAP"
                value = var.result_configmap_name
              }

              volume_mount {
                name       = "script"
                mount_path = "/scripts"
              }
            }

            volume {
              name = "script"
              config_map {
                name         = kubernetes_config_map_v1.attestation_script.metadata[0].name
                default_mode = "0555"
              }
            }
          }
        }
      }
    }
  }
}
