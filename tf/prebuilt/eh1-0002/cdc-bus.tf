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

# Debezium's real sink and offset topics; the CDC scene does not create them.
resource "kubernetes_namespace_v1" "cdc_bus" {
  metadata { name = "cdc-bus" }
}
module "cdc_bus" {
  source     = "../../modules/living-stacks/streaming/tf/modules/kafka_strimzi"
  namespace  = kubernetes_namespace_v1.cdc_bus.metadata[0].name
  system     = "primary"
  kubeconfig = var.kubeconfig_path
  depends_on = [module.image_preload]
}
