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
  description = "Namespace this stack's own workload (the chart, the order-flow KafkaTopic's owning resource name) deploys into (stack.sh's NS)"
  default     = "storefront"
}

variable "system" {
  type        = string
  description = "Short instance label, used for living-stack=$system (stack.sh's SYSTEM)"
  default     = "primary"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in ../modules/order_flow_topic's and ../modules/flagd_scenario's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "kafka_bootstrap" {
  type        = string
  description = "Bootstrap address of the shared Strimzi Kafka the order flow publishes to (stack.sh's KAFKA_BOOTSTRAP)"
  default     = "kafka-kafka-bootstrap.data-platform.svc:9092"
}

variable "kafka_namespace" {
  type        = string
  description = "Namespace the order-flow KafkaTopic CR is applied into (stack.sh's KAFKA_NS; must match the namespace kafka_bootstrap actually lives in, with a Strimzi cluster named \"kafka\")"
  default     = "data-platform"
}

variable "topic_prefix" {
  type        = string
  description = "When set, dot-prefixes the order-flow topic name so two SYSTEMs can share one Kafka bus (stack.sh's TOPIC_PREFIX)"
  default     = ""
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
  description = "Disable opentelemetry-collector.presets.hostMetrics (see ../modules/shop_chart/variables.tf). Not part of values-gke.yaml and not set by stack.sh; set true only on a GKE Autopilot cluster, where that preset's hostfs hostPath mount is rejected by the Warden admission policy."
  default     = false
}

variable "scenario" {
  type        = string
  description = "flagd scenario applied as the last bring-up step (stack.sh always applies baseline at the end of up_gke; see otel-demo/scenarios/ for the full set)"
  default     = "baseline"

  validation {
    condition = contains([
      "baseline",
      "payment-failures",
      "recommendation-cache-failure",
      "product-catalog-failure",
      "memory-leak",
      "kitchen-sink",
    ], var.scenario)
    error_message = "scenario must be one of baseline, payment-failures, recommendation-cache-failure, product-catalog-failure, memory-leak, kitchen-sink (see ../../scenarios/)."
  }
}

variable "scenario_json_override" {
  type        = string
  description = "Optional complete flagd configuration JSON. When null, the checked-in file selected by scenario is used; when set, scenario remains the human-readable annotation while this content is applied."
  default     = null

  validation {
    condition     = var.scenario_json_override == null ? true : can(jsondecode(var.scenario_json_override))
    error_message = "scenario_json_override must be valid JSON when set."
  }
}

variable "collector_values" {
  type = object({
    presets = optional(any)
    config  = optional(any)
  })
  description = "Optional opentelemetry-collector chart values layered after the scene defaults. The surface is limited to the collector's presets and config trees so Helm remains the sole owner of collector objects."
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
  description = "Optional per-component resource requests and limits, layered through the chart's components.<name>.resources values surface."
  default     = {}
}
