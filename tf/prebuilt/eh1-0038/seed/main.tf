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

# seed: the platform's logs-delivery policy, and the maintenance change that turned it
# into an outage.
#
# overrides: the platform runs the collector's OpenSearch logs exporter under a "never
# drop audit logs" policy: retries never give up, and the sending queue is large. It
# also runs the collector at log level warn, a common production setting against log
# noise: the exporter's per-record retry messages are info level, so the collector's
# log shows the memory limiter refusing data but not why. At info level the first page
# of the collector log named the guard, and three of four round-1 solvers went straight
# to it (8b46c66e651e). That is ordinary, declared configuration (the scene's registered
# collector_values override), not the fault.
#
# objects: the maintenance change, CHG-4417. Compliance's "PII guard" ingest pipeline
# for the customer-audit indices, and its index template, whose patterns also include
# otel-logs-* by mistake; the change applied the pipeline to the matching existing
# indices too. One redacted customer-audit record shows the guard's real use. The
# fail processor rejects every record lacking a redaction marker the collector never
# adds, and OpenSearch answers each such bulk item with status 500
# (fail_processor_exception; measured on OpenSearch 3.7.0, 2026-09-18), which the
# exporter retries (contrib v0.156.0, log_bulk_indexer.go shouldRetryEvent:
# 429/500/502/503/504), so the queue grows until the collector's shared
# memory_limiter refuses every pipeline, traces included.
#
# The Job is named like a change ticket, carries the change-window label and deletes
# itself 30 s after it completes; startup-sync (status.tf) holds the apply until it is
# gone and the chain has formed, so its script is never readable during an attempt. Its
# events remain, as a real change would leave them. The script is comment-free.
locals {
  overrides = {
    collector_values = {
      config = {
        exporters = {
          opensearch = {
            retry_on_failure = {
              enabled          = true
              initial_interval = "5s"
              max_interval     = "30s"
              max_elapsed_time = "0s"
            }
            sending_queue = {
              enabled    = true
              queue_size = 100000
            }
          }
        }
        service = {
          telemetry = {
            logs = { level = "warn" }
          }
        }
      }
    }
  }

  maintenance = <<-SH
    set -eu
    OS=opensearch
    http() {
      (
        exec 3<>"/dev/tcp/$OS/9200"
        printf '%s %s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "$1" "$2" "$OS" "$${#3}" "$3" >&3
        sed '1,/^\r$/d' <&3
      )
    }
    for i in $(seq 1 60); do
      http GET /_cluster/health "" | grep -q '"status"' && break
      sleep 5
    done
    # Each call must be acknowledged (a partial fault must never reach a solver): a call
    # that is not is retried, and after a minute the Job fails, which fails the apply.
    put() {
      for i in $(seq 1 12); do
        out=$(http PUT "$1" "$2") || out=""
        echo "$out"
        case "$out" in *'"acknowledged":true'*) return 0 ;; esac
        sleep 5
      done
      return 1
    }
    put /_ingest/pipeline/pii-guard '{"description":"PII guard for the customer-audit-* indices: reject records that have not passed PII redaction","processors":[{"fail":{"if":"ctx.containsKey(\"pii_redacted\") == false","message":"record rejected by pii-guard: missing PII redaction marker"}}]}'
    put /_index_template/customer-audit '{"index_patterns":["customer-audit-*","otel-logs-*"],"priority":50,"template":{"settings":{"index.default_pipeline":"pii-guard"}},"_meta":{"owner":"compliance","change":"CHG-4417","purpose":"customer audit records must pass PII redaction before they are indexed"}}'
    put '/otel-logs-*/_settings' '{"index.default_pipeline":"pii-guard"}'
    for i in $(seq 1 12); do
      out=$(http POST '/customer-audit-2026-09/_doc?refresh=true' "{\"@timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"account.export\",\"subject\":\"[redacted]\",\"pii_redacted\":true}") || out=""
      echo "$out"
      case "$out" in *'"result":"created"'*) break ;; esac
      [ "$i" -lt 12 ] || exit 1
      sleep 5
    done
  SH
}

output "overrides" {
  value = local.overrides
}

output "objects" {
  value = {
    "storefront/Job/chg-4417" = {
      apiVersion = "batch/v1", kind = "Job"
      metadata = {
        name      = "chg-4417"
        namespace = "storefront"
        labels    = { "app.kubernetes.io/component" = "change-window" }
      }
      spec = {
        backoffLimit            = 6
        ttlSecondsAfterFinished = 30
        template = {
          spec = {
            restartPolicy = "Never"
            containers = [{
              name    = "apply"
              image   = "bitnamilegacy/kubectl:1.29"
              command = ["bash", "-c", local.maintenance]
            }]
          }
        }
      }
    }
  }
}
