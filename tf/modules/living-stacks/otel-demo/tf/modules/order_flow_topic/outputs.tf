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

output "topic_name" {
  value       = var.topic_name
  description = "Actual Kafka topic name the order flow publishes to and consumes from"
}

output "resource_name" {
  value       = var.resource_name
  description = "Name of the KafkaTopic CR"
}

output "kafka_namespace" {
  value       = var.kafka_namespace
  description = "Namespace the KafkaTopic CR was applied into"
}
