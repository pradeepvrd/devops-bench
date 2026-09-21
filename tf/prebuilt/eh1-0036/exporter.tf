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

# settlement-status: the Scene Status Exporter the declarative-verification policy
# prescribes for data-plane outcomes. A read-only scene component that reads the
# two sinks and the order ledger and serves JSON over HTTP; task.yaml checks it with
# native http_probe. It is never invoked through pod_exec.
#
# Two constraints, both deliberate:
#   - It lives in finance-reporting, which is NOT in the solver's edit namespaces,
#     so the component being graded against cannot be edited or deleted by the run.
#   - It reports sink-level outcomes only, symmetrically for both sinks. No key names
#     which job is at fault or which is protected: the solver can reach this endpoint,
#     and a key like that would hand over the answer the task exists to test.
# How the two loops below work. These notes live here, outside the scripts, because
# the scripts ship into the cluster where a solver can read them, and nothing
# grader-internal should (the first final audit found these comments inside them):
#   - topics: every pass reads the newest 30 records of each orders.enriched
#     partition by offset (about 90 overall, about a minute of orders, so a correct
#     repair shows within about a minute) (never from the beginning: the topic keeps an hour, so the
#     beginning is the oldest data and would grade the pre-repair world), and marks
#     product enrichment fresh if events.product.enriched grew since three passes ago
#     (~60s; one quiet 20s pass is ordinary at this profile).
#   - ledger: publishes a starting status before the first pass (hold entries read
#     from t0, and a missing file would be a 404), then computes: complete = at least
#     95% of recent enriched orders carry a customer tier; totals agree = per-tier
#     sums by the enriched tier match per-tier sums by the ledger's true tier within
#     1%, with untiered value at most 1% of the window. It logs one line per pass.
locals {
  exporter_ns = "finance-reporting"

  topics_loop = <<-SH
    set -u
    B="kafka-kafka-bootstrap.${var.streaming_namespace}.svc:9092"
    o1=0; o2=0; o3=0
    while true; do
      : > /shared/recent.json
      /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server "$B" --topic orders.enriched --time -1 2>/dev/null \
        | while IFS=: read -r _ p end; do
            start=$(( end > 30 ? end - 30 : 0 ))
            [ "$end" -gt "$start" ] || continue
            /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$B" --topic orders.enriched \
              --partition "$p" --offset "$start" --max-messages $(( end - start )) \
              --timeout-ms 15000 2>/dev/null >> /shared/recent.json
          done
      awk '{ id=""; t="null"; tot=0
                 if (match($0,/"order_id":[0-9]+/)) { id=substr($0,RSTART+11,RLENGTH-11) }
                 if (match($0,/"customer_tier":"[^"]*"/)) { t=substr($0,RSTART+17,RLENGTH-18) }
                 if (match($0,/"total":[0-9.]+/)) { tot=substr($0,RSTART+8,RLENGTH-8) }
                 if (id!="") print id "\t" t "\t" tot }' /shared/recent.json > /shared/enriched.tsv.tmp
      mv /shared/enriched.tsv.tmp /shared/enriched.tsv
      end=$(/opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server "$B" --topic events.product.enriched --time -1 2>/dev/null \
            | awk -F: '{s+=$3} END {print s+0}')
      if [ "$o3" -eq 0 ] || [ "$end" -gt "$o3" ]; then echo true > /shared/events_fresh; else echo false > /shared/events_fresh; fi
      o3=$o2; o2=$o1; o1=$end
      sleep 20
    done
  SH

  ledger_loop = <<-SH
    set -u
    mkdir -p /shared/www
    printf '{"orders_complete": false, "totals_agree": false, "events_fresh": true}\n' > /shared/www/status
    while true; do
      if [ -s /shared/enriched.tsv ]; then
        ids=$(cut -f1 /shared/enriched.tsv | paste -sd, -)
        psql -tA -F$'\t' -c "select o.id, c.tier from orders o join customers c on c.id=o.customer_id where o.id in ($ids)" \
          > /shared/truth.tsv 2>/dev/null || true
        complete=$(awk -F'\t' '{n++; if ($2!="null" && $2!="") k++} END {print (n>0 && k/n>=0.95) ? "true" : "false"}' /shared/enriched.tsv)
        agree=$(awk -F'\t' 'NR==FNR { truth[$1]=$2; next }
                 { all+=$3; if ($2=="null" || $2=="") { lost+=$3 } else { e[$2]+=$3 }
                   if ($1 in truth) l[truth[$1]]+=$3 }
                 END { ok=(all>0)
                       if (all>0 && lost/all>0.01) ok=0
                       for (k in l) { d=e[k]-l[k]; if (d<0) d=-d; if (l[k]>0 && d/l[k]>0.01) ok=0 }
                       for (k in e) if (!(k in l)) ok=0
                       print ok ? "true" : "false" }' /shared/truth.tsv /shared/enriched.tsv)
        fresh=$(cat /shared/events_fresh 2>/dev/null || echo false)
        printf '{"orders_complete": %s, "totals_agree": %s, "events_fresh": %s}\n' \
          "$complete" "$agree" "$fresh" > /shared/www/status.tmp
        mv /shared/www/status.tmp /shared/www/status
        echo "$(date -u +%H:%M:%S) records=$(wc -l < /shared/enriched.tsv) untiered=$(awk -F'\t' '$2=="null" || $2==""' /shared/enriched.tsv | wc -l) status=$(cat /shared/www/status)"
      fi
      sleep 20
    done
  SH
}

resource "kubernetes_namespace_v1" "exporter" {
  metadata { name = local.exporter_ns }
  depends_on = [module.cluster]
}

data "kubernetes_secret_v1" "scene_superuser" {
  metadata {
    name      = "shop-superuser"
    namespace = var.scene_namespace
  }
  depends_on = [module.scene_cdc]
}

resource "kubernetes_secret_v1" "ledger_reader" {
  metadata {
    name      = "ledger-reader"
    namespace = local.exporter_ns
  }
  data = {
    PGHOST     = "shop-rw.${var.scene_namespace}.svc"
    PGDATABASE = "shop"
    PGUSER     = data.kubernetes_secret_v1.scene_superuser.data["username"]
    PGPASSWORD = data.kubernetes_secret_v1.scene_superuser.data["password"]
  }
  depends_on = [kubernetes_namespace_v1.exporter]
}

resource "kubectl_manifest" "exporter" {
  for_each = {
    deployment = {
      apiVersion = "apps/v1", kind = "Deployment"
      metadata   = { name = "settlement-status", namespace = local.exporter_ns }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "settlement-status" } }
        template = {
          metadata = { labels = { app = "settlement-status" } }
          spec = {
            volumes = [{ name = "shared", emptyDir = {} }]
            containers = [
              {
                name         = "topics"
                image        = var.kafka_image
                command      = ["bash", "-c", local.topics_loop]
                volumeMounts = [{ name = "shared", mountPath = "/shared" }]
              },
              {
                name         = "ledger"
                image        = var.postgres_image
                command      = ["bash", "-c", local.ledger_loop]
                envFrom      = [{ secretRef = { name = "ledger-reader" } }]
                volumeMounts = [{ name = "shared", mountPath = "/shared" }]
              },
              {
                name         = "http"
                image        = "busybox:1.36"
                command      = ["sh", "-c", "mkdir -p /shared/www && exec httpd -f -p 8080 -h /shared/www"]
                ports        = [{ containerPort = 8080 }]
                volumeMounts = [{ name = "shared", mountPath = "/shared" }]
              },
            ]
          }
        }
      }
    }
    service = {
      apiVersion = "v1", kind = "Service"
      metadata   = { name = "settlement-status", namespace = local.exporter_ns }
      spec       = { selector = { app = "settlement-status" }, ports = [{ port = 8080, targetPort = 8080 }] }
    }
  }
  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait_for_rollout  = true
  depends_on        = [kubernetes_secret_v1.ledger_reader, module.scene_streaming]
}
