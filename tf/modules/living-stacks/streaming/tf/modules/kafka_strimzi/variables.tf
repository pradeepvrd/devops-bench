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
  description = "Namespace the Strimzi operator, Kafka cluster, and KafkaTopic CRs deploy into (this stack's own workload namespace, i.e. stack.sh's NS)"
}

variable "system" {
  type        = string
  description = "living-stack label value for this instance (stack.sh's SYSTEM)"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in this module's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy (e.g. another process running `gcloud container clusters get-credentials` for a different cluster), pointing kubectl at the wrong cluster mid-run."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "topic_prefix" {
  type        = string
  description = "When set, dot-prefixes every topic name and dash-prefixes every KafkaTopic resource name so more than one system can share one Kafka bus (stack.sh's TOPIC_PREFIX / RESOURCE_PREFIX)"
  default     = ""
}

variable "create_cdc_topics" {
  type        = bool
  description = "Create the cdc.public.{customers,products,orders,order_items} and cdc-offsets/cdc-schema-history KafkaTopic CRs this Kafka cluster's own enrichment jobs need to reach RUNNING (see main.tf's header comment on cdc_topics for why this scene, not cdc/tf/scene, owns them). Set false if some other instance on this cluster already created them, or if this scene is deployed standalone with no enrichment jobs consuming cdc.public.*."
  default     = true
}

variable "debezium_topic_prefix" {
  type        = string
  description = "cdc/tf/scene's debezium_topic_prefix output (defaults to 'cdc', matching that scene's own default topic_prefix of \"\")"
  default     = "cdc"
}

variable "offsets_topic" {
  type        = string
  description = "cdc/tf/scene's offsets_topic output"
  default     = "cdc-offsets"
}

variable "schema_history_topic" {
  type        = string
  description = "cdc/tf/scene's schema_history_topic output"
  default     = "cdc-schema-history"
}

variable "strimzi_chart_version" {
  type        = string
  description = "strimzi-kafka-operator helm chart version"
  default     = "1.2.0"
}

variable "create_global_resources" {
  type        = bool
  description = "Create Strimzi's cluster-scoped ClusterRoles/ClusterRoleBindings. Set false when a prior instance on the same cluster already created them, matching stack.sh's strimzi_helm_args()."
  default     = true
}

variable "nodepool_replicas" {
  type        = number
  description = "KafkaNodePool broker+controller replica count. Defaults match overlays/gke/kafka-nodepool-patch.yaml, the shape this module is validated against."
  default     = 3
}

variable "nodepool_storage_type" {
  type        = string
  description = "KafkaNodePool storage type: 'ephemeral' (stack.sh's kind lane) or 'persistent-claim' (stack.sh's gke lane)"
  default     = "persistent-claim"

  validation {
    condition     = contains(["ephemeral", "persistent-claim"], var.nodepool_storage_type)
    error_message = "nodepool_storage_type must be one of ephemeral, persistent-claim."
  }
}

variable "nodepool_storage_size" {
  type        = string
  description = "PVC size per broker, only used when nodepool_storage_type = persistent-claim"
  default     = "10Gi"
}

variable "nodepool_cpu" {
  type        = string
  description = "Per-broker CPU request/limit"
  default     = "250m"
}

variable "nodepool_memory" {
  type        = string
  description = "Per-broker memory request/limit"
  default     = "1Gi"
}

variable "kafka_ready_timeout" {
  type        = string
  description = "kubectl wait timeout for the Kafka CR's Ready condition (measured cold on kind, 2026-09-06: 93s; 300s is roughly 3x, see spec 'Verified on kind')"
  default     = "300s"
}

variable "topic_config_overrides" {
  type        = map(map(string))
  description = "Per-topic Kafka config overrides, keyed by this module's own logical topic key (events_raw, events_agg, orders_enriched, product_activity, events_product_enriched, cdc_public_customers, cdc_public_products, cdc_public_orders, cdc_public_order_items, cdc_offsets, cdc_schema_history). Each value is merged over that topic's base config map, taking precedence on any key it repeats."
  default     = {}
}

variable "kafka_cr_overrides" {
  type = object({
    listeners = optional(list(object({
      name           = string
      port           = number
      type           = string
      tls            = bool
      authentication = optional(object({ type = string }))
    })))
    pod_disruption_budget = optional(object({
      max_unavailable = number
    }))
  })
  description = "Overrides spliced into the Kafka CR. listeners replaces the module's single internal:9092 listener wholesale when set. pod_disruption_budget is additive: the CR sets no spec.kafka.template.podDisruptionBudget at all by default, so setting this adds one rather than modifying an existing field."
  default     = {}
}

variable "generate_network_policy" {
  type        = bool
  description = "Whether Strimzi generates NetworkPolicy resources. When false, the caller owns complete ingress policy coverage for brokers and operators; NetworkPolicy allowances are additive."
  default     = true
  nullable    = false
}
