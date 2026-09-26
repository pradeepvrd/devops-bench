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

output "cnpg_namespace" {
  value       = module.cnpg_postgres.cnpg_namespace
  description = "Namespace the CloudNativePG operator is installed into"
}

output "primary_service" {
  value       = module.cnpg_postgres.primary_service
  description = "Postgres read-write service DNS name"
}

output "superuser_secret_name" {
  value       = module.cnpg_postgres.superuser_secret_name
  description = "Secret holding the postgres superuser credentials"
}

output "app_secret_name" {
  value       = module.cnpg_postgres.app_secret_name
  description = "Secret holding the initdb 'app' owner credentials"
}

output "debezium_secret_name" {
  value       = kubernetes_secret_v1.cdc_debezium_credentials.metadata[0].name
  description = "Secret holding the 'debezium' role's credentials"
}

output "debezium_deployment_name" {
  value       = module.debezium_server.deployment_name
  description = "Name of the debezium-server Deployment"
}

output "oltp_writer_deployment_name" {
  value       = module.oltp_writer.deployment_name
  description = "Name of the oltp-writer Deployment"
}

output "debezium_topic_prefix" {
  value       = local.debezium_topic_prefix
  description = "Debezium's topic.prefix, for a future streaming-scene KafkaTopic wiring"
}

output "offsets_topic" {
  value       = local.offsets_topic
  description = "Debezium's offset-storage topic name, for a future streaming-scene KafkaTopic wiring"
}

output "schema_history_topic" {
  value       = local.schema_history_topic
  description = "Debezium's schema-history topic name, for a future streaming-scene KafkaTopic wiring"
}
