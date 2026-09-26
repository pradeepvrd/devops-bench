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

variable "kubeconfig" {
  type        = string
  description = "Path to the kubeconfig file used to connect to the Kubernetes cluster."
  default     = ""
}

variable "system" {
  type        = string
  description = "System or attempt label assigned to resources managed by this module."
  default     = "primary"
}

variable "gateway_namespace" {
  type        = string
  description = "Namespace for the shared Gateway and controller fixture."
  default     = "gateway-system"
}

variable "create_namespace" {
  type        = bool
  description = "Whether to create the gateway_namespace if it does not already exist."
  default     = true
}

variable "install_crds" {
  type        = bool
  description = "Whether to install Gateway API standard CRDs (GatewayClass, Gateway, HTTPRoute, GRPCRoute, ReferenceGrant)."
  default     = true
}

variable "gateway_api_version" {
  type        = string
  description = "Release version of the Kubernetes Gateway API standard CRDs."
  default     = "v1.2.0"
}

variable "crds_manifest_source" {
  type        = string
  description = "Manifest URL or local file path for Gateway API standard CRD manifests. If unset or null, defaults to $${path.module}/manifests/standard-install-v1.2.0.yaml via locals."
  default     = null
}

variable "crds_manifest_url" {
  type        = string
  description = "Optional custom URL or local path for Gateway API standard CRD manifests (legacy alias for crds_manifest_source)."
  default     = null
}

variable "crds_ready_timeout" {
  type        = string
  description = "Timeout for waiting for Gateway API CRDs to reach the Established condition."
  default     = "180s"
}

variable "install_shared_gateway" {
  type        = bool
  description = "Whether to deploy the shared GatewayClass and Gateway fixture so workloads can attach routes declaratively."
  default     = true
}

variable "gateway_class_name" {
  type        = string
  description = "Name of the GatewayClass object."
  default     = "shared-gateway-class"
}

variable "controller_name" {
  type        = string
  description = "Controller name declared by the GatewayClass."
  default     = "living-stacks.devops-bench.io/gateway-fixture"
}

variable "gateway_name" {
  type        = string
  description = "Name of the shared Gateway object."
  default     = "shared-gateway"
}

variable "gateway_port" {
  type        = number
  description = "HTTP listener port exposed by the shared Gateway when listeners is not specified."
  default     = 80
}

variable "listeners" {
  type = list(object({
    name                    = string
    protocol                = string
    port                    = number
    hostname                = optional(string)
    allowed_routes_selector = optional(any)
  }))
  description = "Configurable Gateway listeners (name, protocol, port, hostname, allowed_routes_selector). If null or empty, defaults to a single HTTP listener on gateway_port."
  default     = null
}

variable "gateway_listeners" {
  type = list(object({
    name                    = string
    protocol                = string
    port                    = number
    hostname                = optional(string)
    allowed_routes_selector = optional(any)
  }))
  description = "Alias for listeners."
  default     = null
}

variable "install_controller_fixture" {
  type        = bool
  description = "Whether to deploy a lightweight controller fixture Deployment and Service in the gateway namespace."
  default     = true
}

variable "controller_image" {
  type        = string
  description = "Container image for the Gateway controller fixture Deployment."
  default     = "devops-bench/traffic-engine:1.0.0"
}

variable "controller_replicas" {
  type        = number
  description = "Number of replicas for the controller fixture Deployment."
  default     = 1
}
