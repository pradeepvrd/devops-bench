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

locals {
  task_sql_scripts = {
    "wide-watermark.sql" = templatefile("${path.module}/sql/wide-watermark.sql", {
      SYSTEM           = "primary"
      EVENTS_RAW_TOPIC = "events.raw"
      EVENTS_AGG_TOPIC = "events.agg"
      KAFKA_BOOTSTRAP  = "kafka-kafka-bootstrap.streaming.svc:9092"
      GCS_RAW_PATH     = "file:///flink-data/raw/"
    })
  }
}
resource "kubernetes_annotations" "profile_context" {
  api_version = "v1"
  kind        = "Secret"
  metadata {
    name      = "traffic-profile"
    namespace = "streaming"
  }
  annotations = {
    "kubernetes.io/change-cause"                  = "Mobile-sync delay experiment ended. Normal synthetic traffic has late_fraction=0 and late_max_seconds=1; other traffic-shape settings are unchanged."
    "operations.living-stacks.io/profile-loading" = "The producer loads its profile once on process startup."
  }
  depends_on = [module.scene_streaming]
}
resource "kubernetes_annotations" "rollup_contract" {
  api_version = "flink.apache.org/v1beta1"
  kind        = "FlinkSessionJob"
  metadata {
    name      = "core"
    namespace = "streaming"
  }
  annotations = {
    "operations.living-stacks.io/window-finalization-budget" = "Watermark delay must not exceed 30 seconds. This is a watermark budget, not a 30-second total event-to-output SLA for a one-minute window."
    "operations.living-stacks.io/recovery-source"            = "Raw events remain in events.raw and the raw archive; changing future input does not backfill emitted aggregates."
  }
  depends_on = [module.scene_streaming]
}
