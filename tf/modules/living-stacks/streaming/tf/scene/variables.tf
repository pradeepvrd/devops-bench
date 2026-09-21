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
  description = "Namespace this stack's own workload (Kafka, Flink, traffic-engine) deploys into (stack.sh's NS)"
  default     = "streaming"
}

variable "system" {
  type        = string
  description = "Short instance label, used for living-stack=$system and in Flink job names / Kafka consumer group ids (stack.sh's SYSTEM)"
  default     = "primary"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in ../modules/kafka_strimzi's, ../modules/flink_platform's, and ../modules/flink_sql_job's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "topic_prefix" {
  type        = string
  description = "When set, prefixes every topic name so more than one system can share one Kafka bus (stack.sh's TOPIC_PREFIX)"
  default     = ""
}

variable "strimzi_chart_version" {
  type    = string
  default = "1.2.0"
}

variable "create_global_resources" {
  type        = bool
  description = "Create Strimzi's cluster-scoped ClusterRoles/ClusterRoleBindings. Set false when a prior instance on the same cluster already created them."
  default     = true
}

variable "kafka_nodepool_replicas" {
  type    = number
  default = 3
}

variable "kafka_nodepool_storage_type" {
  type        = string
  description = "'ephemeral' (stack.sh's kind lane) or 'persistent-claim' (stack.sh's gke lane, this scene's validated shape)"
  default     = "persistent-claim"
}

variable "kafka_nodepool_storage_size" {
  type    = string
  default = "10Gi"
}

variable "checkpoints_dir" {
  type        = string
  description = "Flink state.checkpoints.dir. Defaults to a file:// path on the session pod's own emptyDir (no GCP identity required); pass a gs:// URL plus flink_gsa_email for a gke-shaped deployment with a real bucket."
  default     = "file:///flink-data/checkpoints"
}

variable "savepoints_dir" {
  type        = string
  description = "Flink execution.checkpointing.savepoint-dir, required for FlinkSessionJob's default upgradeMode: savepoint to reconcile at all -- see ../modules/flink_platform/variables.tf for the live error this fixes."
  default     = "file:///flink-data/savepoints"
}

variable "raw_archive_path" {
  type        = string
  description = "GCS_RAW_PATH substituted into job.sql's events_raw_archive sink. Defaults to file:// (see checkpoints_dir); pass a gs:// URL for a real archive."
  default     = "file:///flink-data/raw/"
}

variable "enriched_archive_path" {
  type        = string
  description = "GCS_ENRICHED_PATH substituted into enrichment-orders.sql's orders_enriched_archive sink. Defaults to file:// (see checkpoints_dir); pass a gs:// URL for a real archive."
  default     = "file:///flink-data/enriched/"
}

variable "flink_gsa_email" {
  type        = string
  description = "Google service account email for Workload Identity, only needed when checkpoints_dir/raw_archive_path/enriched_archive_path are gs:// URLs. Leave null (default) for the file://-backed default."
  default     = null
}

variable "owner" {
  type        = string
  description = "Passed straight through to ../modules/flink_platform's owner, for the factory303.io/owner label on the JobManager PodDisruptionBudget. Leave null (default) if the caller does not track per-attempt ownership."
  default     = null
}

variable "jar_path" {
  type        = string
  description = "Path to the built SQL runner jar. null (default) resolves to streaming/sql-runner/target/flink-sql-runner-1.0.0.jar relative to this module -- a variable default cannot itself contain a path.module reference, so the real default is applied in main.tf via coalesce()."
  default     = null
}

variable "core_sql_path" {
  type        = string
  description = "null (default) resolves to streaming/overlays/gke/sql/job.sql relative to this module; see jar_path for why this is null here rather than a literal relative default."
  default     = null
}

variable "enrichment_orders_sql_path" {
  type        = string
  description = "null (default) resolves to streaming/overlays/gke/sql/enrichment-orders.sql relative to this module; see jar_path."
  default     = null
}

variable "enrichment_events_sql_path" {
  type        = string
  description = "null (default) resolves to streaming/overlays/gke/sql/enrichment-events.sql relative to this module; see jar_path."
  default     = null
}

variable "profile_json_path" {
  type        = string
  description = "Traffic profile JSON (stack.sh's profiles/ or overlays/<lane>/profile.json). null (default) resolves to streaming/overlays/gke/profile.json relative to this module; see jar_path."
  default     = null
}

variable "profile_json_override" {
  type        = string
  description = "When set, used verbatim as the traffic profile JSON content instead of file(profile_json_path). Lets a caller drive the running traffic-engine through a sequence of profile revisions (e.g. a task's seed/repair overlay) without checking in a file per revision."
  default     = null
}

variable "extra_sql_scripts" {
  type        = map(string)
  description = "Additional filename => rendered SQL content pairs merged into the session cluster's sql_scripts ConfigMap, alongside job.sql/enrichment-orders.sql/enrichment-events.sql. Lets more than one revision of the core job's SQL exist on the session cluster at once (e.g. an approved job.sql plus a task's seeded variant), so core_sql_filename below can select between them."
  default     = {}
}

variable "core_sql_filename" {
  type        = string
  description = "Which key of the combined sql_scripts map (job.sql plus extra_sql_scripts) the core FlinkSessionJob's args points at. Changing this (not editing job.sql's own content) is how a caller drives the core job through a FlinkSessionJob upgradeMode: savepoint stop/redeploy/restore cycle declaratively: the operator diffs spec.job.args itself, so pointing at a different filename is a real CR spec change, where editing a mounted ConfigMap's content in place is not (the operator has no visibility into file contents, only its own CR spec)."
  default     = "job.sql"
}

variable "traffic_engine_image" {
  type    = string
  default = "devops-bench/traffic-engine:1.0.0"
}

variable "traffic_profile_as_configmap" {
  type        = bool
  description = "Passed to ../modules/traffic_engine's profile_as_configmap."
  default     = false
}

variable "enable_governance_attestation" {
  type        = bool
  description = "Deploy the per-topic retention governance attestation CronJob (../modules/governance_attestation). Off by default so existing callers of this scene see no change."
  default     = false
}

variable "governance_attestation_topic_retention_policy" {
  type        = map(string)
  description = "Passed straight through to ../modules/governance_attestation's topic_retention_policy when enable_governance_attestation is true (map of actual Kafka topic name, e.g. 'events.raw', to required retention.ms). Ignored otherwise."
  default     = {}
}

variable "governance_attestation_schedule" {
  type        = string
  description = "Passed straight through to ../modules/governance_attestation's schedule when enable_governance_attestation is true. Ignored otherwise."
  default     = "0 2 * * *"
}

variable "topic_config_overrides" {
  type        = map(map(string))
  description = "Passed straight through to ../modules/kafka_strimzi's topic_config_overrides. Per-topic Kafka config overrides, keyed by logical topic key (events_raw, events_agg, orders_enriched, product_activity, events_product_enriched, cdc_public_customers, cdc_public_products, cdc_public_orders, cdc_public_order_items, cdc_offsets, cdc_schema_history)."
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
  description = "Passed straight through to ../modules/kafka_strimzi's kafka_cr_overrides."
  default     = {}
}
