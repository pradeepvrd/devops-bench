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

variable "namespace" {
  type        = string
  description = "Namespace this stack's own workload (Postgres, oltp-writer, debezium-server) deploys into (stack.sh's NS)"
  default     = "orders-db"
}

variable "system" {
  type        = string
  description = "Short instance label, used for living-stack=$system (stack.sh's SYSTEM)"
  default     = "primary"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in ../modules/cnpg_postgres's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "kafka_bootstrap" {
  type        = string
  description = "Bootstrap address of the shared Kafka bus Debezium writes to (stack.sh's KAFKA_BOOTSTRAP). The Kafka cluster and its KafkaTopic CRs are a streaming-scene concern, out of scope here; see README."
  default     = "kafka-kafka-bootstrap.data-platform.svc:9092"
}

variable "topic_prefix" {
  type        = string
  description = "When set, dot-prefixes Debezium's topic.prefix and its offset/schema-history topic names so more than one system can share one Kafka bus (stack.sh's TOPIC_PREFIX)"
  default     = ""
}

variable "profile" {
  type        = string
  description = "oltp-writer traffic profile (stack.sh's PROFILE)"
  default     = "calm"

  validation {
    condition     = contains(["calm", "rush-hour", "churny"], var.profile)
    error_message = "profile must be one of calm, rush-hour, churny (see ../../profiles/)."
  }
}

variable "install_operator" {
  type        = bool
  description = "Install the CloudNativePG operator via helm. Set false when a prior instance on this cluster already installed it."
  default     = true
}

variable "cnpg_namespace" {
  type        = string
  description = "Namespace for the cluster-wide CloudNativePG operator. The scene passes this through but does not own the shared namespace; a caller that owns the cluster lifecycle should create and destroy it."
  default     = "cnpg-system"
}

variable "cnpg_chart_version" {
  type        = string
  description = "cloudnative-pg helm chart version"
  default     = "0.29.0"
}

variable "instances" {
  type        = number
  description = "Number of Postgres instances (1 primary + N-1 streaming replicas)"
  default     = 2
}

variable "postgres_image" {
  type        = string
  description = "CNPG-managed Postgres image"
  default     = "ghcr.io/cloudnative-pg/postgresql:18.6"
}

variable "debezium_image" {
  type        = string
  description = "Debezium Server image"
  default     = "quay.io/debezium/server:3.6.1.Final"
}

variable "oltp_writer_image" {
  type        = string
  description = "Base image oltp-writer runs on"
  default     = "devops-bench/oltp-writer:1.0.0"
}

variable "oltp_writer_replicas" {
  type        = number
  description = "Passed straight through to ../modules/oltp_writer's replicas."
  default     = 1
}

variable "oltp_writer_profile_override" {
  type        = string
  description = "When set, used verbatim as oltp-writer's traffic profile JSON content instead of file(cdc/profiles/<profile>.json). Lets a caller drive the running oltp-writer through a sequence of profile revisions (e.g. a task's seed/repair overlay) without checking in a file per revision, matching ../../streaming/tf/scene's profile_json_override."
  default     = null
}
