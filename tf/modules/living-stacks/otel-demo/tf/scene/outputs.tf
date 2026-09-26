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

output "release_name" {
  value       = module.shop_chart.release_name
  description = "Name of the opentelemetry-demo helm release (otel-demo-$namespace)"
}

output "kafka_topic" {
  value       = local.kafka_topic
  description = "Order-flow Kafka topic name (stack.sh's KAFKA_TOPIC)"
}

output "topic_resource_name" {
  value       = local.topic_resource_name
  description = "Name of the order-flow KafkaTopic CR"
}

output "kafka_namespace" {
  value       = var.kafka_namespace
  description = "Namespace the order-flow KafkaTopic CR was applied into"
}

output "applied_scenario" {
  value       = module.flagd_scenario.scenario_name
  description = "Name of the flagd scenario currently applied"
}
