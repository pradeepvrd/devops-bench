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

output "namespace" {
  value       = kubernetes_namespace_v1.this.metadata[0].name
  description = "This instance's owned workload namespace"
}

output "kafka_bootstrap" {
  value       = module.kafka.kafka_bootstrap
  description = "Bootstrap address of this instance's Kafka cluster"
}

output "topics" {
  value       = module.kafka.topics
  description = "Map of logical topic name to actual Kafka topic name"
}

output "flink_deployment_name" {
  value       = module.flink.deployment_name
  description = "Name of the session FlinkDeployment CR"
}

output "flink_rest_service" {
  value       = module.flink.rest_service
  description = "In-cluster address of the session cluster's REST endpoint"
}

output "jar_filename" {
  value       = module.flink.jar_filename
  description = "Filename of the SQL runner jar mounted onto the operator pod, used to build each FlinkSessionJob's file:// jarURI"
}

output "flink_session_jobs" {
  value = {
    core              = module.core_job.job_name
    enrichment_orders = module.enrichment_orders_job.job_name
    enrichment_events = module.enrichment_events_job.job_name
  }
  description = "Names of the three FlinkSessionJob CRs this scene submits"
}

output "traffic_engine_deployment_name" {
  value       = module.traffic_engine.deployment_name
  description = "Name of the traffic-engine Deployment"
}

output "governance_attestation_cron_job_name" {
  value       = try(module.governance_attestation[0].cron_job_name, null)
  description = "Name of the governance attestation CronJob, null when enable_governance_attestation is false"
}

output "governance_attestation_result_configmap_name" {
  value       = try(module.governance_attestation[0].result_configmap_name, null)
  description = "Name of the ConfigMap the attestation writes its verdict to, null when enable_governance_attestation is false"
}
