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
  description = "Namespace the chart installs into (this stack's own workload namespace, i.e. stack.sh's NS)"
}

variable "system" {
  type        = string
  description = "living-stack label value for this instance (stack.sh's SYSTEM)"
}

variable "kafka_bootstrap" {
  type        = string
  description = "Bootstrap address of the shared Strimzi Kafka the order flow publishes to (stack.sh's KAFKA_BOOTSTRAP)"
}

variable "kafka_topic" {
  type        = string
  description = "Order-flow Kafka topic name, already including any TOPIC_PREFIX dot-prefix (stack.sh's KAFKA_TOPIC)"
}

variable "values_common_path" {
  type        = string
  description = "Path to values-common.yaml (caller supplies otel-demo/values-common.yaml, unchanged and unrendered)"
}

variable "chart_version" {
  type        = string
  description = "opentelemetry-demo helm chart version"
  default     = "0.41.0"
}

variable "load_gen_vus" {
  type        = string
  description = "Override the load generator's virtual-user count (stack.sh's LOAD_GEN_VUS). Leave null to use values-common.yaml's default of 10."
  default     = null
}

variable "helm_timeout" {
  type        = number
  description = "helm_release wait timeout in seconds (stack.sh uses --timeout 15m)"
  default     = 900
}

variable "disable_collector_host_metrics" {
  type        = bool
  description = "Disable opentelemetry-collector.presets.hostMetrics, which mounts a hostfs hostPath volume the chart's default values enable. Not part of values-gke.yaml and not something stack.sh sets; set true only on a GKE Autopilot cluster, where that hostPath mount is rejected outright by the Warden admission policy."
  default     = false
}

variable "collector_values" {
  type = object({
    presets = optional(any)
    config  = optional(any)
  })
  description = "Optional opentelemetry-collector presets and config values layered after the scene defaults."
  default     = {}
}

variable "component_resources" {
  type = map(object({
    requests = optional(object({
      cpu    = optional(string)
      memory = optional(string)
    }))
    limits = optional(object({
      cpu    = optional(string)
      memory = optional(string)
    }))
  }))
  description = "Optional per-component resources layered after the scene defaults."
  default     = {}
}
