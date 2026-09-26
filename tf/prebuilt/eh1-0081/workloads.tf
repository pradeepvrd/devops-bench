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

# The incident's workloads, all ordinary tenant objects the solver can read and edit:
#   streaming/mobile-outbox        forwards events mobile clients buffered offline into
#                                  mobile.late-events (minutes late)
#   streaming/late-event-replay    CronJob, every 10 minutes: one Kafka transaction per run moves
#                                  a batch from mobile.late-events into events.raw with its
#                                  source offsets (REPLAY_MAX_EVENTS was raised to 400000 by
#                                  CHG-6231, "yesterday"; harmless until the backlog grows)
#   storefront/server-events       the storefront backend's transactional publisher of checkout
#                                  and cart events into events.raw (healthy 2 s transactions
#                                  until the seed applies CHG-6240)
# plus the two teams' change logs (written by the seed so their times match the run). Healthy at
# apply time; the seed Job injects the incident.
locals {
  replay_src = {
    "Outbox.java" = file("${path.module}/files/Outbox.java")
    "Replay.java" = file("${path.module}/files/Replay.java")
  }

  workload_objects = {
    mobile_topic = {
      apiVersion = "kafka.strimzi.io/v1", kind = "KafkaTopic"
      metadata   = { name = "mobile-late-events", namespace = local.ns, labels = { "strimzi.io/cluster" = "kafka" } }
      spec       = { topicName = "mobile.late-events", partitions = 3, replicas = 1, config = { "retention.ms" = "604800000" } }
    }
    replay_src = {
      apiVersion = "v1", kind = "ConfigMap"
      metadata   = { name = "mobile-replay-src", namespace = local.ns }
      data       = local.replay_src
    }
    replay_config = {
      apiVersion = "v1", kind = "ConfigMap"
      metadata   = { name = "late-event-replay", namespace = local.ns }
      data = {
        REPLAY_MAX_EVENTS      = "400000"
        TRANSACTION_TIMEOUT_MS = "900000"
        SOURCE_TOPIC           = "mobile.late-events"
        TARGET_TOPIC           = "events.raw"
        GROUP_ID               = "late-event-replay"
      }
    }
    outbox = {
      apiVersion = "apps/v1", kind = "Deployment"
      metadata   = { name = "mobile-outbox", namespace = local.ns, labels = { app = "mobile-outbox" } }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "mobile-outbox" } }
        template = {
          metadata = { labels = { app = "mobile-outbox" } }
          spec = {
            containers = [{
              name         = "outbox"
              image        = var.kafka_image
              command      = ["sh", "-c", "exec java -Xmx96m -cp '/opt/kafka/libs/*' /src/Outbox.java"]
              env          = [{ name = "EVENTS_PER_SEC", value = "4" }]
              resources    = { requests = { cpu = "50m", memory = "160Mi" }, limits = { memory = "256Mi" } }
              volumeMounts = [{ name = "src", mountPath = "/src" }]
            }]
            volumes = [{ name = "src", configMap = { name = "mobile-replay-src" } }]
          }
        }
      }
    }
    replay = {
      apiVersion = "batch/v1", kind = "CronJob"
      metadata   = { name = "late-event-replay", namespace = local.ns, labels = { app = "late-event-replay" } }
      spec = {
        schedule                   = "*/10 * * * *"
        concurrencyPolicy          = "Forbid"
        successfulJobsHistoryLimit = 3
        failedJobsHistoryLimit     = 3
        jobTemplate = {
          spec = {
            backoffLimit = 0
            template = {
              metadata = { labels = { app = "late-event-replay" } }
              spec = {
                restartPolicy = "Never"
                containers = [{
                  name         = "replay"
                  image        = var.kafka_image
                  command      = ["sh", "-c", "exec java -XX:+ExitOnOutOfMemoryError -cp '/opt/kafka/libs/*' /src/Replay.java"]
                  envFrom      = [{ configMapRef = { name = "late-event-replay" } }]
                  resources    = { requests = { cpu = "100m", memory = "256Mi" }, limits = { memory = "256Mi" } }
                  volumeMounts = [{ name = "src", mountPath = "/src" }]
                }]
                volumes = [{ name = "src", configMap = { name = "mobile-replay-src" } }]
              }
            }
          }
        }
      }
    }
    streaming_changes = {
      apiVersion = "v1", kind = "ConfigMap"
      metadata   = { name = "streaming-changes", namespace = local.ns }
      data       = { "changes.md" = "" } # written by the seed with timestamps relative to the run
    }
    server_events_src = {
      apiVersion = "v1", kind = "ConfigMap"
      metadata   = { name = "server-events-src", namespace = local.sf_ns }
      data       = { "ServerEvents.java" = file("${path.module}/files/ServerEvents.java") }
    }
    server_events_config = {
      apiVersion = "v1", kind = "ConfigMap"
      metadata   = { name = "server-events", namespace = local.sf_ns }
      data = {
        COMMIT_INTERVAL_MS     = "2000"
        COMMIT_MAX_RECORDS     = "5000"
        TRANSACTION_TIMEOUT_MS = "900000"
        TRANSACTIONAL_ID       = "storefront-server-events"
        TOPIC                  = "events.raw"
        KAFKA_BOOTSTRAP        = "kafka-kafka-bootstrap.streaming.svc:9092"
      }
    }
    server_events = {
      apiVersion = "apps/v1", kind = "Deployment"
      metadata   = { name = "server-events", namespace = local.sf_ns, labels = { app = "server-events" } }
      spec = {
        replicas = 1
        strategy = { type = "Recreate" }
        selector = { matchLabels = { app = "server-events" } }
        template = {
          metadata = { labels = { app = "server-events" } }
          spec = {
            terminationGracePeriodSeconds = 30
            containers = [{
              name         = "publisher"
              image        = var.kafka_image
              command      = ["sh", "-c", "exec java -Xmx96m -cp '/opt/kafka/libs/*' /src/ServerEvents.java"]
              envFrom      = [{ configMapRef = { name = "server-events" } }]
              resources    = { requests = { cpu = "50m", memory = "192Mi" }, limits = { memory = "256Mi" } }
              volumeMounts = [{ name = "src", mountPath = "/src" }]
            }]
            volumes = [{ name = "src", configMap = { name = "server-events-src" } }]
          }
        }
      }
    }
    storefront_changes = {
      apiVersion = "v1", kind = "ConfigMap"
      metadata   = { name = "storefront-changes", namespace = local.sf_ns }
      data       = { "changes.md" = "" } # written by the seed with timestamps relative to the run
    }
  }
}

resource "kubernetes_namespace_v1" "storefront" {
  metadata { name = local.sf_ns }
  depends_on = [module.cluster]
}

resource "kubectl_manifest" "workloads" {
  for_each = local.workload_objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = contains(["outbox", "server_events"], each.key)

  depends_on = [module.scene_streaming, kubernetes_namespace_v1.storefront]
}
