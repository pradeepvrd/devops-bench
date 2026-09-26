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

variable "cluster_name" {
  type        = string
  description = "Name of the kind cluster to preload images into (the value passed as --name to `kind create cluster` / `kind get nodes`). Every node this cluster reports, not just `<cluster_name>-control-plane`, receives every image: node_count defaults to 1 in this repo's kind-module invocations, but is a variable, so a stack root running more workers still gets full coverage."

  validation {
    condition     = length(trimspace(var.cluster_name)) > 0
    error_message = "cluster_name must be a non-empty kind cluster name."
  }
}

variable "images" {
  type        = list(string)
  description = "Fully-qualified image references to ensure present on the host and import into every node of cluster_name. Defaults to the six images Task 13 mirrored into the private Artifact Registry namespace this module exists to work around."

  default = [
    "ghcr.io/cloudnative-pg/postgresql:18.6",
    "quay.io/debezium/server:3.6.1.Final",
    "devops-bench/oltp-writer:1.0.0",
    "docker.io/library/flink:1.20",
    "registry.k8s.io/kubectl:v1.31.5",
    "devops-bench/traffic-engine:1.0.0",
  ]

  validation {
    condition     = length(var.images) > 0
    error_message = "images must not be empty; a preload with nothing to preload is not this module's job."
  }

  validation {
    condition     = alltrue([for img in var.images : length(trimspace(img)) > 0])
    error_message = "images entries must be non-empty image references."
  }

  validation {
    condition     = length(var.images) == length(distinct(var.images))
    error_message = "images must not contain duplicates; each entry is pulled and imported once."
  }
}

variable "import_platform" {
  type        = string
  description = "Platform pinned on the `ctr images import --platform` call into each node's containerd. Must match the kind node's own platform (linux/amd64 on every kind host this repo runs against); this is exactly the pin `kind load docker-image`'s own --all-platforms import has no way to set, which is why that path fails on manifest-list images (flink, debezium-server, kubectl) and this module exists."
  default     = "linux/amd64"

  validation {
    condition     = length(trimspace(var.import_platform)) > 0
    error_message = "import_platform must be a non-empty platform string, e.g. linux/amd64."
  }
}
