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

output "cron_job_name" {
  value       = kubernetes_cron_job_v1.attestation.metadata[0].name
  description = "Name of the governance attestation CronJob, for kubectl create job --from=cronjob/<name>"
}

output "result_configmap_name" {
  value       = var.result_configmap_name
  description = "Name of the ConfigMap the attestation writes its verdict to"
}

output "service_account_name" {
  value       = kubernetes_service_account_v1.attestation.metadata[0].name
  description = "ServiceAccount the attestation Pod runs as"
}
