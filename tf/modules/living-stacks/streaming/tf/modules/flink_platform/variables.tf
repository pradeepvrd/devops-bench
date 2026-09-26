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
  description = "Namespace the session FlinkDeployment, its SQL scripts, and the SQL runner jar ConfigMap deploy into (this stack's own workload namespace, i.e. stack.sh's NS). The Flink operator itself installs into a dedicated flink-operator-<namespace> namespace this module creates."
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

variable "flink_operator_chart_version" {
  type        = string
  description = "flink-kubernetes-operator helm chart version"
  default     = "1.15.0"
}

variable "flink_operator_image_repo" {
  type    = string
  default = "ghcr.io/apache/flink-kubernetes-operator"
}

variable "flink_operator_image_tag" {
  type    = string
  default = "1.15.0"
}

variable "jar_allowed_schemes" {
  type        = string
  description = "kubernetes.operator.user.artifacts.allowed-schemes value. Semicolon-delimited, not comma-delimited -- see main.tf's header comment for why this matters. Includes file because the operator fetches the jar from a mounted ConfigMap, not an in-cluster HTTP host: flink-kubernetes-operator 1.15.0's fix for CVE-2026-40564 permanently rejects http(s) jarURIs resolving to loopback, link-local, site-local, or any-local addresses, which an in-cluster Service always does."
  default     = "https;http;file"
}

variable "session_cluster_image" {
  type    = string
  default = "docker.io/library/flink:1.20"
}

variable "flink_version" {
  type    = string
  default = "v1_20"
}

variable "taskmanager_slots" {
  type        = number
  description = "taskmanager.numberOfTaskSlots. Defaults to 4, matching overlays/gke/flink-gcs-patch.yaml: job.sql's job (1) plus enrichment-orders.sql and enrichment-events.sql (1 each), plus one slot of headroom."
  default     = 4
}

variable "checkpoint_interval" {
  type    = string
  default = "30s"
}

variable "checkpoints_dir" {
  type        = string
  description = "state.checkpoints.dir. Defaults to the base/kind-shaped file:// path on the session pod's own emptyDir; pass a gs:// URL (and flink_gsa_email) for a gke-shaped deployment with a real bucket."
  default     = "file:///flink-data/checkpoints"
}

variable "savepoints_dir" {
  type        = string
  description = "execution.checkpointing.savepoint-dir. Required for ../flink_sql_job's default upgradeMode: savepoint to reconcile at all (confirmed live: the operator refuses to upgrade/redeploy a session job with 'Job could not be upgraded with savepoint while config key[execution.checkpointing.savepoint-dir] is not set' otherwise). Defaults to a file:// path alongside checkpoints_dir; pass a gs:// URL for a gke-shaped deployment."
  default     = "file:///flink-data/savepoints"
}

variable "managed_memory_fraction" {
  type        = string
  description = "taskmanager.memory.managed.fraction. Defaults match overlays/gke/flink-gcs-patch.yaml's fix for the heap-OOM restart loop three SQL jobs hit under the default 40 percent fraction."
  default     = "0.1"
}

variable "tolerable_failed_checkpoints" {
  type    = number
  default = 3
}

variable "kafka_connector_version" {
  type    = string
  default = "3.4.0-1.20"
}

variable "jobmanager_cpu" {
  type    = string
  default = "1"
}

variable "jobmanager_memory" {
  type    = string
  default = "1536m"
}

variable "taskmanager_cpu" {
  type        = string
  description = "Defaults match overlays/gke/flink-gcs-patch.yaml's taskManager.resource.cpu (run at its honest size now that NAP can provision new nodes for it)."
  default     = "1.0"
}

variable "taskmanager_memory" {
  type        = string
  description = "Defaults match overlays/gke/flink-gcs-patch.yaml's taskManager.resource.memory."
  default     = "2048m"
}

variable "sql_scripts" {
  type        = map(string)
  description = "Map of filename to fully-rendered Flink SQL content, mounted into the session cluster's podTemplate at /sql-jobs/<filename>. Render job.sql/enrichment-orders.sql/enrichment-events.sql with templatefile() at the call site."
  default     = {}
}

variable "jar_path" {
  type        = string
  description = "Path to the built SQL runner jar (streaming/sql-runner/target/flink-sql-runner-1.0.0.jar)"
}

variable "jar_filename" {
  type    = string
  default = "flink-sql-runner-1.0.0.jar"
}

variable "session_ready_timeout_seconds" {
  type        = number
  description = "Seconds to poll jobManagerDeploymentStatus before giving up (measured cold on kind, 2026-09-06: 36s; 180s is roughly 5x, kept above a 3-minute floor for a slower node's cold image pull, see spec 'Verified on kind')"
  default     = 180
}

variable "teardown_crs_absence_timeout_seconds" {
  type        = number
  description = "Seconds to poll for the FlinkDeployment and FlinkSessionJob CRs' own genuine absence in this module's namespace, on destroy, before the operator's Helm release is allowed to be torn down. No native resource tracks the operator's own cancellation-with-savepoint teardown timing for these CRs (mirrors cdc_postgres's teardown_pod_absence_timeout_seconds for CNPG's own pod teardown), so this bounds the hand-rolled poll (main.tf's null_resource.crs_absence_poll). Deliberately generous relative to cdc_postgres's own default: a FlinkSessionJob delete triggers a stop-with-savepoint, which is slower than a plain pod teardown."
  default     = 300
}

variable "flink_gsa_email" {
  type        = string
  description = "Google service account email to annotate the operator-created 'flink' ServiceAccount with, for Workload Identity access to a gs:// checkpoints_dir. Leave null (default) for a file://-backed deployment that needs no GCP identity."
  default     = null
}

variable "owner" {
  type        = string
  description = "Value for the factory303.io/owner label on the JobManager PodDisruptionBudget, matching factory-303/src/factory303/stream_runtime.py's LABEL/owner_id convention its jobmanager-disruption-budget health gate checks. Leave null (default) if no caller tracks per-attempt ownership; the label is then omitted."
  default     = null
}
