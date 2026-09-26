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
  description = "Namespace to deploy debezium-server into"
}

variable "system" {
  type        = string
  description = "living-stack label value for this instance"
}

variable "application_properties" {
  type        = string
  description = "Fully-rendered debezium-server application.properties content (render templates/application.properties.tftpl at the call site with templatefile(), same shape as cdc/debezium-server-application.properties)"
}

variable "db_password_secret_name" {
  type        = string
  description = "Name of the basic-auth Secret holding the 'debezium' role's password (cdc-debezium-credentials in stack.sh)"
  default     = "cdc-debezium-credentials"
}

variable "image" {
  type        = string
  description = "Debezium Server image"
  default     = "quay.io/debezium/server:3.6.1.Final"
}
