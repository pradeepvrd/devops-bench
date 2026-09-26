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

# seed: Faults R3 + R6
#
# overrides:
#   R6: collector_values passes a secondary scrape receiver prometheus/legacy-compat
#       into receivers and into service.pipelines.metrics.receivers.
#       This scrapes checkout:8080 directly in addition to standard metrics ingestion,
#       producing duplicate checkout_requests_total series and doubling
#       sum(rate(checkout_requests_total[2m])) from ~2.0 req/s to ~4.0 req/s.
#   Synthetic error traffic: scenario_json_override sets paymentFailure defaultVariant to "10%"
#       so checkout experiences ~8% error rate (~0.16 req/s errors out of ~2.00 req/s requests).
#
# objects:
#   R3: A seed Job (storefront/Job/setup-alert-rules) and its RBAC that patches
#       ConfigMap/prometheus in namespace storefront to configure the alerting rule:
#       group "checkout-slo", alert "CheckoutHighErrorRate":
#       expr: (sum by (service_name, tenant) (rate(checkout_errors_total[2m])) / sum by (service, tenant) (rate(checkout_requests_total[2m]))) > 0.05
#       and triggers a reload of Prometheus via its lifecycle endpoint (or restarts the pod).
#
locals {
  scenario_json = jsonencode({
    "$schema" = "https://flagd.dev/schema/v0/flags.json"
    flags = {
      adFailure = {
        defaultVariant = "off"
        description    = "Fail ad service"
        state          = "ENABLED"
        variants       = { "off" = false, "on" = true }
      }
      adHighCpu = {
        defaultVariant = "off"
        description    = "Triggers high cpu load in the ad service"
        state          = "ENABLED"
        variants       = { "off" = false, "on" = true }
      }
      adManualGc = {
        defaultVariant = "off"
        description    = "Triggers full manual garbage collections in the ad service"
        state          = "ENABLED"
        variants       = { "off" = false, "on" = true }
      }
      cartFailure = {
        defaultVariant = "off"
        description    = "Fail cart service n% of the time"
        state          = "ENABLED"
        variants       = { "10%" = 0.1, "100%" = 1, "25%" = 0.25, "50%" = 0.5, "75%" = 0.75, "90%" = 0.9, "off" = 0 }
      }
      emailMemoryLeak = {
        defaultVariant = "off"
        description    = "Memory leak in the email service."
        state          = "ENABLED"
        variants       = { "10000x" = 10000, "1000x" = 1000, "100x" = 100, "10x" = 10, "1x" = 1, "off" = 0 }
      }
      failedReadinessProbe = {
        defaultVariant = "off"
        description    = "readiness probe failure for cart service"
        state          = "ENABLED"
        variants       = { "off" = false, "on" = true }
      }
      imageSlowLoad = {
        defaultVariant = "off"
        description    = "slow loading images in the frontend"
        state          = "ENABLED"
        variants       = { "10sec" = 10000, "5sec" = 5000, "off" = 0 }
      }
      intlShippingSlowdown = {
        defaultVariant = "off"
        description    = "Delays international shipping responses to simulate overseas shipping delay"
        state          = "ENABLED"
        variants       = { "10sec" = 10, "5sec" = 5, "off" = 0 }
      }
      kafkaQueueProblems = {
        defaultVariant = "off"
        description    = "Overloads Kafka queue while simultaneously introducing a consumer side delay leading to a lag spike"
        state          = "ENABLED"
        variants       = { "off" = 0, "on" = 100 }
      }
      loadGeneratorTraffic = {
        defaultVariant = "on"
        description    = "Enable synthetic traffic from the load generator."
        state          = "ENABLED"
        variants       = { "off" = 0, "on" = 1 }
      }
      loadGeneratorVUs = {
        defaultVariant = "10"
        description    = "Number of concurrent virtual users."
        state          = "ENABLED"
        variants       = { "10" = 10, "25" = 25, "5" = 5, "50" = 50 }
      }
      paymentFailure = {
        defaultVariant = "10%"
        description    = "Fail payment service charge requests n%"
        state          = "ENABLED"
        variants = {
          "10%"  = 0.1
          "100%" = 1
          "25%"  = 0.25
          "50%"  = 0.5
          "75%"  = 0.75
          "90%"  = 0.95
          "off"  = 0
        }
      }
      paymentUnreachable = {
        defaultVariant = "off"
        description    = "Payment service is unavailable"
        state          = "ENABLED"
        variants       = { "off" = false, "on" = true }
      }
      productCatalogFailure = {
        defaultVariant = "off"
        description    = "Fail product catalog service on a specific product"
        state          = "ENABLED"
        variants       = { "off" = false, "on" = true }
      }
      recommendationCacheFailure = {
        defaultVariant = "off"
        description    = "Fail recommendation service cache"
        state          = "ENABLED"
        variants       = { "off" = false, "on" = true }
      }
    }
  })

  collector_presets = {
    hostMetrics    = { enabled = false }
    kubeletMetrics = { enabled = false }
    clusterMetrics = { enabled = false }
  }

  overrides = {
    scenario_json_override = local.scenario_json
    collector_values = {
      presets = local.collector_presets
      config = {
        receivers = {
          "prometheus/checkout" = {
            config = {
              scrape_configs = [
                {
                  job_name        = "checkout-primary"
                  scrape_interval = "5s"
                  metrics_path    = "/metrics"
                  static_configs = [
                    {
                      targets = ["checkout-metrics.storefront.svc.cluster.local:8080"]
                    }
                  ]
                }
              ]
            }
          }
          "prometheus/legacy-compat" = {
            config = {
              scrape_configs = [
                {
                  job_name        = "checkout-legacy"
                  scrape_interval = "5s"
                  metrics_path    = "/legacy-metrics"
                  static_configs = [
                    {
                      targets = ["checkout-metrics.storefront.svc.cluster.local:8080"]
                    }
                  ]
                }
              ]
            }
          }
        }
        service = {
          pipelines = {
            metrics = {
              receivers = [
                "otlp",
                "kafkametrics",
                "span_metrics",
                "prometheus/ad",
                "receiver_creator/metrics",
                "prometheus/checkout",
                "prometheus/legacy-compat",
              ]
            }
          }
        }
      }
    }
  }

  setup_script = <<-SH
    set -eu
    for i in $(seq 1 60); do
      kubectl -n storefront get cm prometheus && break
      sleep 2
    done

    cat <<'EOF' > /tmp/prometheus.yml
    global:
      scrape_interval: 5s
      evaluation_interval: 5s
    rule_files:
    - /etc/config/alerting_rules.yml
    scrape_configs:
    - job_name: prometheus
      static_configs:
      - targets:
        - localhost:9090
    - job_name: opentelemetry-collector
      scrape_interval: 5s
      metrics_path: /collector-metrics
      static_configs:
      - targets:
        - otel-collector-metrics.storefront.svc.cluster.local:8888
    EOF

    cat <<'EOF' > /tmp/alerting_rules.yml
    groups:
    - name: checkout-slo
      rules:
      - alert: CheckoutHighErrorRate
        expr: (sum by (service_name, tenant) (rate(checkout_errors_total[2m])) / sum by (service, tenant) (rate(checkout_requests_total[2m]))) > 0.05
        for: 0s
        labels:
          severity: critical
          tenant: storefront
        annotations:
          summary: "Checkout error rate is elevated above 5%"
    EOF

    kubectl -n storefront create configmap prometheus \
      --from-file=prometheus.yml=/tmp/prometheus.yml \
      --from-file=alerting_rules.yml=/tmp/alerting_rules.yml \
      --dry-run=client -o yaml | kubectl -n storefront patch configmap prometheus --patch-file /dev/stdin

    kubectl -n storefront rollout restart deployment/prometheus
    kubectl -n storefront rollout status deployment/prometheus --timeout=180s

    # Wait until Prometheus has scraped opentelemetry-collector (up == 1) and ingested at least 2 samples of checkout_requests_total
    for i in $(seq 1 60); do
      if kubectl -n storefront get pods -l app.kubernetes.io/name=opentelemetry-collector | grep -q "1/1"; then
        sleep 12
        break
      fi
      sleep 2
    done
  SH
  objects = {
    "storefront/ServiceAccount/setup-alert-rules" = {
      apiVersion = "v1", kind = "ServiceAccount"
      metadata   = { name = "setup-alert-rules", namespace = "storefront" }
    }
    "storefront/Role/setup-alert-rules" = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "Role"
      metadata   = { name = "setup-alert-rules", namespace = "storefront" }
      rules = [
        {
          apiGroups = ["", "apps"]
          resources = ["configmaps", "pods", "deployments", "replicasets"]
          verbs     = ["get", "list", "watch", "patch", "update"]
        }
      ]
    }
    "storefront/RoleBinding/setup-alert-rules" = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "RoleBinding"
      metadata   = { name = "setup-alert-rules", namespace = "storefront" }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "setup-alert-rules" }
      subjects   = [{ kind = "ServiceAccount", name = "setup-alert-rules", namespace = "storefront" }]
    }
    "storefront/Job/setup-alert-rules" = {
      apiVersion = "batch/v1", kind = "Job"
      metadata   = { name = "setup-alert-rules", namespace = "storefront" }
      spec = {
        backoffLimit = 6
        template = {
          spec = {
            serviceAccountName = "setup-alert-rules"
            restartPolicy      = "Never"
            containers = [{
              name    = "setup"
              image   = "bitnamilegacy/kubectl:1.29"
              command = ["bash", "-c", local.setup_script]
            }]
          }
        }
      }
    }
  }
}
