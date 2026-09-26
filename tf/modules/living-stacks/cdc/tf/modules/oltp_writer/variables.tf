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
  description = "Namespace to deploy oltp-writer into"
}

variable "system" {
  type        = string
  description = "living-stack label value for this instance"
}

variable "script_path" {
  type        = string
  description = "Path to oltp_writer.py (caller supplies cdc/oltp_writer.py)"
}

variable "profile_json" {
  type        = string
  description = "Contents of the selected traffic profile JSON (caller supplies cdc/profiles/<name>.json)"
}

variable "profile_name" {
  type        = string
  description = "Name of the selected profile, recorded as the living-stacks.cdc/profile annotation (matches stack.sh's ensure_profile_configmap)"
  default     = "calm"
}

variable "pg_service" {
  type        = string
  description = "Postgres read-write service DNS name"
  default     = "shop-rw"
}

variable "app_secret_name" {
  type        = string
  description = "Name of the Secret holding the initdb 'app' owner credentials"
  default     = "shop-app"
}

variable "image" {
  type        = string
  description = "Base image oltp-writer runs on"
  default     = "devops-bench/oltp-writer:1.0.0"
}

variable "replicas" {
  type        = number
  description = "oltp-writer Deployment replica count"
  default     = 1
}
