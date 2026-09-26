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

variable "kafka_namespace" {
  type        = string
  description = "Namespace the shared Strimzi Kafka cluster lives in, and the namespace this KafkaTopic CR is applied into (stack.sh's KAFKA_NS)"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in this module's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy (e.g. another process running `gcloud container clusters get-credentials` for a different cluster), pointing kubectl at the wrong cluster mid-run."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "namespace" {
  type        = string
  description = "This stack's own workload namespace (stack.sh's NS), used only to keep the CR's resource name unique across instances sharing kafka_namespace"
}

variable "resource_name" {
  type        = string
  description = "KafkaTopic CR resource name (stack.sh names this otel-demo-orders-$NS so multiple storefront instances never collide on CR name)"
}

variable "system" {
  type        = string
  description = "living-stack label value for this instance (stack.sh's SYSTEM)"
}

variable "topic_name" {
  type        = string
  description = "Actual Kafka topic name (spec.topicName), already including any TOPIC_PREFIX dot-prefix (stack.sh's KAFKA_TOPIC)"
}

variable "partitions" {
  type        = number
  description = "Topic partition count"
  default     = 3
}

variable "retention_ms" {
  type        = string
  description = "Topic retention.ms"
  default     = "3600000"
}

variable "topic_ready_timeout" {
  type        = string
  description = "kubectl wait timeout for the KafkaTopic CR's Ready condition"
  default     = "180s"
}
