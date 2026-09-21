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

output "kafka_bootstrap" {
  value       = "kafka-kafka-bootstrap.${var.namespace}.svc:9092"
  description = "Bootstrap address of this instance's Kafka cluster (stack.sh's KAFKA_BOOTSTRAP)"
}

output "topics" {
  value       = { for key, topic in local.topics : key => topic.topic_name }
  description = "Map of logical topic name (events_raw, events_agg, orders_enriched, product_activity, events_product_enriched, plus cdc_public_customers/products/orders/order_items and cdc_offsets/cdc_schema_history when create_cdc_topics is true) to actual Kafka topic name"
}

output "namespace" {
  value       = var.namespace
  description = "Namespace this instance's Kafka cluster deploys into"
}
