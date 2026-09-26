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
  description = "Namespace the attestation CronJob, its ServiceAccount/Role, and its result ConfigMap live in (the stack's own stream namespace, so it can exec into that namespace's broker pod)"
}

variable "kafka_cluster_name" {
  type        = string
  description = "Strimzi Kafka CR name (../kafka_strimzi always names it 'kafka')"
  default     = "kafka"
}

variable "broker_pool_name" {
  type        = string
  description = "KafkaNodePool name carrying the strimzi.io/pool-name label on broker pods (../kafka_strimzi always names its pool 'dual-role')"
  default     = "dual-role"
}

variable "topic_retention_policy" {
  type        = map(string)
  description = "Map of the actual broker-side Kafka topic name (e.g. 'events.raw', not the KafkaTopic CR's resource name) to its required retention.ms under the data-class policy this attestation enforces"
}

variable "result_configmap_name" {
  type        = string
  description = "Name of the ConfigMap this attestation writes its verdict to: data.status (pass|fail), data.checked_at, data.failing_topics, data.checked_topics"
  default     = "governance-attestation-result"
}

variable "schedule" {
  type        = string
  description = "Cron schedule for the nightly run, matching the story's own 'nightly' framing. A bounded task window also needs a fresh reading on demand: see catalog/tasks/S-020a/checks/attestation_passes.py, which triggers a one-off Job from this CronJob's own template (kubectl create job --from=cronjob/...) rather than waiting for the schedule."
  default     = "0 2 * * *"
}

variable "suspend" {
  type        = bool
  description = "Suspend the CronJob's own nightly schedule. kubectl create job --from=cronjob/... does not consult suspend, so on-demand triggers still work regardless of this setting."
  default     = false
}

variable "attestation_image" {
  type        = string
  description = "Image supplying kubectl and a POSIX shell for the attestation script, which execs into a live broker pod to run that pod's own bundled kafka-configs.sh rather than shipping a separate Kafka client image here"
  # Previously pointed at bitnami/kubectl:1.31.5, which no longer exists on
  # Docker Hub (Bitnami's 2025 change dropped versioned free-tier tags; only
  # a rolling `latest` remains under bitnami/kubectl, and the
  # bitnamilegacy/ migration namespace has no 1.31.5 either, only a floating
  # 1.31-debian-12). That moved this to the official upstream
  # registry.k8s.io/kubectl:v1.31.5 (M0b, 2026-09-07). It is now mirrored to
  # our own Artifact Registry below, like the other five image variables in
  # this repo.
  #
  # Caveat specific to this image: kind nodes cannot authenticate to the
  # private Artifact Registry, so a kind-hosted run needs this image
  # sideloaded, exactly like the other mirrored images (see stagehand
  # docs/superpowers/notes/2026-09-07-image-delivery-to-kind.md, including
  # that a bare `kind load docker-image` fails on multi-architecture
  # images). Pointing at the public upstream tag would have avoided that
  # for kind specifically. It is pointed at the mirror anyway, for
  # consistency with the other five image variables, and because the
  # images are already sideloaded for kind by whatever brings a scene up.
  default = "registry.k8s.io/kubectl:v1.31.5"
}
