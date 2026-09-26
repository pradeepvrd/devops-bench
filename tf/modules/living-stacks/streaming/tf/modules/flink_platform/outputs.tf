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

output "deployment_name" {
  value       = "streaming-flink"
  description = "Name of the session FlinkDeployment CR (fixed, matching stack.sh's flink-sessioncluster.yaml)"
}

output "rest_service" {
  value       = "streaming-flink-rest.${var.namespace}.svc:8081"
  description = "In-cluster address of the session cluster's REST endpoint"
}

output "jar_filename" {
  value       = var.jar_filename
  description = "Filename of the SQL runner jar mounted onto the operator pod at /sql-runner, for ../flink_sql_job to build its file:// jarURI from"
}

output "sql_scripts_mount_path" {
  value       = "/sql-jobs"
  description = "Path the sql_scripts ConfigMap is mounted at on the session cluster's JobManager pod, where FlinkSessionJob's args must point"
}

output "operator_namespace" {
  value       = local.operator_namespace
  description = "Namespace the flink-kubernetes-operator installs into"
}
