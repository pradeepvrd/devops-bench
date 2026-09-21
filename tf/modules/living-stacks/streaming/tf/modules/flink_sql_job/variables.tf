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
  description = "Namespace the FlinkSessionJob CR deploys into (must match the session cluster's namespace)"
}

variable "job_name" {
  type        = string
  description = "Name of the FlinkSessionJob CR (Kubernetes object name, e.g. 'core', 'enrichment-orders')"
}

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used for every kubectl invocation in this module's local-exec provisioners (including destroy-time). Required, with no default and no fallback to ambient ~/.kube/config or a $KUBECONFIG environment variable: ambient current-context is shared across concurrent processes and can move out from under an in-flight apply/destroy (e.g. another process running `gcloud container clusters get-credentials` for a different cluster), pointing kubectl at the wrong cluster mid-run."

  validation {
    condition     = length(trimspace(var.kubeconfig)) > 0
    error_message = "kubeconfig must be a non-empty path to a kubeconfig file; there is no ambient fallback (see this variable's description)."
  }
}

variable "deployment_name" {
  type        = string
  description = "Name of the target session FlinkDeployment (../flink_platform's deployment_name output)"
}

variable "jar_filename" {
  type        = string
  description = "Filename of the SQL runner jar mounted onto the operator pod at /sql-runner (../flink_platform's jar_filename output), used to build this CR's file:// jarURI"
}

variable "entry_class" {
  type        = string
  description = "Main class the operator submits (streaming/sql-runner's SqlRunner)"
  default     = "livingstacks.flinksql.SqlRunner"
}

variable "args" {
  type        = list(string)
  description = "SQL file path(s) on the session cluster's JobManager pod, e.g. ['/sql-jobs/job.sql']. SqlRunner concatenates more than one file's parsed statements into one TableEnvironment, but every job this scene submits passes exactly one file (see streaming/sql-runner's SqlRunner.java header for why)."
}

variable "parallelism" {
  type    = number
  default = 1
}

variable "upgrade_mode" {
  type        = string
  description = "FlinkSessionJob upgradeMode. 'savepoint' (the default) is required for the stop/redeploy/restore mechanics factory-303/docs/flink-sessionjob-spike.md proved live (savepointTriggerNonce, savepointRedeployNonce)."
  default     = "savepoint"

  validation {
    condition     = contains(["savepoint", "stateless", "last-state"], var.upgrade_mode)
    error_message = "upgrade_mode must be one of savepoint, stateless, last-state."
  }
}

variable "ready_timeout_seconds" {
  type        = number
  description = "Seconds to poll status.jobStatus.state before giving up (measured cold on kind, 2026-09-06: 72s; 180s is roughly 2.5x, see spec 'Verified on kind')"
  default     = 180
}
