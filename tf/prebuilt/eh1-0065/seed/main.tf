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

# seed: arm == "base"
# Fault 1: memory_limiter has inverted percentages: limit_percentage is 25, spike_limit_percentage is 80.
# Baseline collector memory usage (~38%) causes memory_limiter to drop 100% of telemetry.
# Fault 2: cart_requests_total includes high-cardinality session_id label requiring attribute filtering.

locals {
  overrides = {}

  collector_config = <<-EOT
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      prometheus:
        config:
          scrape_configs:
            - job_name: 'otel-collector'
              scrape_interval: 10s
              static_configs:
                - targets: ['0.0.0.0:8888']
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 25
        spike_limit_percentage: 80
      attributes/cardinality:
        actions:
          - key: session_id
            action: upsert
            value: "unbounded-session-cardinality-stream"
      batch:
        send_batch_size: 100
        send_batch_max_size: 200
        timeout: 1s
    exporters:
      debug:
        verbosity: basic
      otlp/sink:
        endpoint: trace-sink.otel-demo.svc.cluster.local:4317
        tls:
          insecure: true
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
    service:
      extensions: [health_check]
      telemetry:
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [otlp/sink, debug]
        metrics:
          receivers: [otlp, prometheus]
          processors: [memory_limiter, attributes/cardinality, batch]
          exporters: [debug]
  EOT

  objects = {
    "otel-demo/ConfigMap/otel-collector-config" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata = {
        name      = "otel-collector-config"
        namespace = "otel-demo"
        labels = {
          "app.kubernetes.io/name" = "opentelemetry-collector"
        }
      }
      data = {
        relay = local.collector_config
      }
    }

    "otel-demo/Deployment/otel-collector" = {
      apiVersion = "apps/v1"
      kind       = "Deployment"
      metadata = {
        name      = "otel-collector"
        namespace = "otel-demo"
      }
      spec = {
        template = {
          metadata = {
            annotations = {
              "checksum/config" = sha256(local.collector_config)
            }
          }
          spec = {
            volumes = [
              {
                name = "opentelemetry-collector-configmap"
                configMap = {
                  name = "otel-collector-config"
                  items = [
                    {
                      key  = "relay"
                      path = "relay.yaml"
                    }
                  ]
                }
              }
            ]
            containers = [
              {
                name = "opentelemetry-collector"
                resources = {
                  requests = {
                    cpu    = "100m"
                    memory = "200Mi"
                  }
                  limits = {
                    memory = "384Mi"
                  }
                }
              }
            ]
          }
        }
      }
    }
  }
}
