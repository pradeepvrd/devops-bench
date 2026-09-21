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
  description = "Namespace to deploy traffic-engine into"
}

variable "script_path" {
  type        = string
  description = "Path to producer.py (caller supplies streaming/producer.py)"
}

variable "profile_json" {
  type        = string
  description = "Contents of the selected traffic profile JSON (caller supplies streaming/profiles/<name>.json or overlays/gke/profile.json)"
}

variable "profile_name" {
  type        = string
  description = "Name of the selected profile, recorded as the living-stacks.streaming/profile annotation"
  default     = "default"
}

variable "kafka_bootstrap" {
  type        = string
  description = "Bootstrap address of the Kafka cluster to produce to (../kafka_strimzi's kafka_bootstrap output)"
}

variable "topic" {
  type        = string
  description = "Topic to produce events.raw records to (../kafka_strimzi's topics.events_raw output)"
}

variable "image" {
  type    = string
  default = "devops-bench/traffic-engine:1.0.0"
}

variable "replicas" {
  type        = number
  description = "Set to 0 to render the Deployment without starting traffic yet, matching factory303/stream_runtime.py's own scale-to-0-then-1 sequencing"
  default     = 1
}

variable "service_account_name" {
  type        = string
  description = "ServiceAccount for the traffic-engine pod. Only matters for a gke-shaped deployment where it needs a Workload Identity annotation; the default Kubernetes-provided account is fine otherwise."
  default     = "default"
}

variable "profile_as_configmap" {
  type        = bool
  description = "When true, creates and mounts traffic-profile as a ConfigMap instead of a Secret (for tasks where the solver must edit ConfigMap/traffic-profile)."
  default     = false
}
