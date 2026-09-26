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

# seed: the scene, as objects and overrides. Applied under every arm.
#
# overrides: scene override keys to values (validated against scenes.yaml).
# objects:   "namespace/kind/name" => full manifest.
#
# The base arm carries the skipped hourly window state (orders-enrichment
# consumer offset fast-forwarded past window B) PLUS Strimzi KafkaTopic
# events-raw configured with truncated retention.ms: 10000 (10 seconds).
locals {
  namespace       = "streaming"
  kafka_image     = "apache/kafka:3.9.0"
  kafka_bootstrap = "kafka-kafka-bootstrap.streaming.svc:9092"

  pipeline_env = <<-EOT
    KAFKA_BOOTSTRAP=kafka-kafka-bootstrap.streaming.svc:9092
    SOURCE_TOPIC=cdc.public.orders
    CUSTOMER_TOPIC=cdc.public.customers
    ENRICHED_TOPIC=orders.enriched
    ROLLUP_TOPIC=events.agg
    ENRICHMENT_GROUP=orders-enrichment
    ROLLUP_GROUP=orders-rollup
    CONNECTOR_SLOT=orders_cdc
  EOT

  pipeline_readme = <<-EOT
    Order enrichment pipeline (platform-owned).

    cdc.public.orders -> orders-enrichment -> orders.enriched -> orders-rollup
    -> events.agg

    orders-cdc-connector captures row changes from the orders table and
    publishes one change event per order to cdc.public.orders. That topic is a
    transport, not an archive: it keeps five hours, because the pipeline is
    expected to stay within seconds of the source.

    orders-enrichment reads cdc.public.orders as group orders-enrichment, joins
    each order to its customer record from the cdc.public.customers dimension,
    and publishes to orders.enriched:

      key   ord-000123
      value {"order_id":"ord-000123","customer_id":"cust-07",
             "customer_name":"Litware Logistics","amount_cents":4215,
             "window":"2026-09-15T08:00Z"}

    Exactly one enriched record per order id. orders.enriched is the retained
    copy of what has been delivered downstream, kept for 24 hours; records in
    it are never rewritten, re-keyed or removed, and consumers downstream of it
    treat a second record for an order id as a double count.

    orders-rollup counts enriched orders per window and publishes the running
    count per window key to events.agg, which is compacted:

      key   2026-09-15T08:00Z
      value {"window":"2026-09-15T08:00Z","orders_enriched":60}

    Finance reconciles events.agg against the orders table once a day.
  EOT

  connector_script = <<-EOT
    #!/bin/sh
    # orders-cdc-connector: publishes one change event per order row.
    set -u
    . /config/pipeline.env

    mark=/state/started

    say() {
      echo "orders-cdc-connector: $1"
    }

    if [ ! -f "$mark" ]; then
      if touch "$mark" 2>/dev/null; then
        say "streaming changes from replication slot $CONNECTOR_SLOT"
        say "flush of the offset store failed: connection reset by peer"
        say "task aborted, the container will be restarted"
        exit 1
      fi
    fi

    say "restarted after an offset store flush failure"
    say "recovered the stored source position; no snapshot required"
    say "resuming streaming from the recovered position on $SOURCE_TOPIC"
    say "caught up with the orders table"

    while true; do
      say "poll: no row changes pending, connector idle and caught up"
      sleep 300
    done
  EOT

  enrichment_script = <<-EOT
    #!/bin/sh
    # orders-enrichment: joins each order to its customer and publishes the
    # enriched record, exactly once per order id.
    set -u
    . /config/pipeline.env

    say() {
      echo "orders-enrichment: $1"
    }

    say "loading the customer dimension from $CUSTOMER_TOPIC"
    /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$KAFKA_BOOTSTRAP" \
      --topic "$CUSTOMER_TOPIC" --from-beginning --timeout-ms 20000 \
      --consumer-property enable.auto.commit=false \
      --property print.key=true --property key.separator='|' \
      > /tmp/dimension.txt 2>/dev/null || true
    say "dimension holds $(grep -c customer_id /tmp/dimension.txt 2>/dev/null || echo 0) customers"

    say "position of group $ENRICHMENT_GROUP before joining:"
    /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server "$KAFKA_BOOTSTRAP" \
      --describe --group "$ENRICHMENT_GROUP" 2>/dev/null || true

    rm -f /tmp/enriched.fifo
    mkfifo /tmp/enriched.fifo
    /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "$KAFKA_BOOTSTRAP" \
      --topic "$ENRICHED_TOPIC" \
      --property parse.key=true --property key.separator='|' \
      < /tmp/enriched.fifo &
    exec 3> /tmp/enriched.fifo

    say "joining group $ENRICHMENT_GROUP on $SOURCE_TOPIC from its committed offsets"
    /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$KAFKA_BOOTSTRAP" \
      --topic "$SOURCE_TOPIC" --group "$ENRICHMENT_GROUP" \
      --consumer-property auto.offset.reset=latest \
      --consumer-property enable.auto.commit=true \
      --consumer-property auto.commit.interval.ms=5000 \
      --property print.key=true --property key.separator='|' |
      while IFS= read -r line; do
        key=$(echo "$line" | cut -d'|' -f1)
        value=$(echo "$line" | cut -d'|' -f2-)
        case "$key" in
          ord-*) ;;
          *) continue ;;
        esac
        cid=$(echo "$value" | sed -n 's/.*"customer_id":"\([^"]*\)".*/\1/p')
        amount=$(echo "$value" | sed -n 's/.*"amount_cents":\([0-9]*\).*/\1/p')
        window=$(echo "$value" | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
        name=$(grep "^$cid|" /tmp/dimension.txt 2>/dev/null |
          sed -n 's/.*"customer_name":"\([^"]*\)".*/\1/p' | head -n1)
        if [ -z "$name" ]; then name=unknown; fi
        printf '%s|{"order_id":"%s","customer_id":"%s","customer_name":"%s","amount_cents":%s,"window":"%s"}\n' \
          "$key" "$key" "$cid" "$name" "$amount" "$window" >&3
        say "enriched $key for $window"
      done

    say "the source consumer exited, the container will be restarted"
  EOT

  rollup_script = <<-EOT
    #!/bin/sh
    # orders-rollup: counts enriched orders per window and republishes the
    # running count per window key.
    set -u
    . /config/pipeline.env

    counts=/tmp/counts

    say() {
      echo "orders-rollup: $1"
    }

    if [ ! -d "$counts" ]; then
      mkdir -p "$counts"
      attempt=0
      while [ "$attempt" -lt 5 ]; do
        out=$(/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server "$KAFKA_BOOTSTRAP" \
          --group "$ROLLUP_GROUP" --topic "$ENRICHED_TOPIC" \
          --reset-offsets --to-earliest --execute 2>&1) && break
        case "$out" in
          *"does not exist"*) break ;;
        esac
        attempt=$((attempt + 1))
        sleep 15
      done
      say "cold start: rebuilding window counts from the start of $ENRICHED_TOPIC"
    fi

    rm -f /tmp/rollup.fifo
    mkfifo /tmp/rollup.fifo
    /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "$KAFKA_BOOTSTRAP" \
      --topic "$ROLLUP_TOPIC" \
      --property parse.key=true --property key.separator='|' \
      < /tmp/rollup.fifo &
    exec 3> /tmp/rollup.fifo

    say "counting $ENRICHED_TOPIC as group $ROLLUP_GROUP"
    /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$KAFKA_BOOTSTRAP" \
      --topic "$ENRICHED_TOPIC" --group "$ROLLUP_GROUP" \
      --from-beginning \
      --consumer-property auto.offset.reset=earliest \
      --consumer-property enable.auto.commit=true \
      --consumer-property auto.commit.interval.ms=5000 \
      --property print.key=true --property key.separator='|' |
      while IFS= read -r line; do
        value=$(echo "$line" | cut -d'|' -f2-)
        window=$(echo "$value" | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
        if [ -z "$window" ]; then continue; fi
        slot=$(printf '%s' "$window" | tr -c 'A-Za-z0-9' '_')
        total=$(cat "$counts/$slot" 2>/dev/null || echo 0)
        case "$total" in
          '' | *[!0-9]*) total=0 ;;
        esac
        total=$((total + 1))
        echo "$total" > "$counts/$slot"
        printf '%s|{"window":"%s","orders_enriched":%s}\n' "$window" "$window" "$total" >&3
      done

    say "the enriched consumer exited, the container will be restarted"
  EOT

  overrides = {
    topic_config_overrides = {
      events_raw = { "retention.ms" = "10000" }
    }
  }

  objects = {
    "streaming/ConfigMap/platform-retention-policy" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata = {
        name      = "platform-retention-policy"
        namespace = local.namespace
        labels = {
          "living-stack-component" = "streaming"
        }
      }
      data = {
        "policy.md" = <<-EOT
          # Data class raw-events: replay horizon

          Scope: topic events.raw in the streaming namespace.
          Required broker retention: 604800000 ms (seven days).

          Seven days is the standard platform retention horizon for raw streaming inputs.
          Retention for events.raw must be maintained declaratively at 604800000 ms via the
          Strimzi KafkaTopic resource (events-raw). Platform operators reconcile topic
          configurations continuously; manual broker overrides will be reverted.
        EOT

        "OPS-5021.md" = <<-EOT
          # OPS-5021: Missing hourly rollup window in aggregated events stream

          Downstream reconciliations reported an hourly window missing from aggregated rollups
          in events.agg while current live events continue arriving normally.
          Investigation requested into pipeline ingestion and connector health.
        EOT
      }
    }

    "streaming/ConfigMap/orders-pipeline-config" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata = {
        name      = "orders-pipeline-config"
        namespace = local.namespace
      }
      data = {
        "pipeline.env" = local.pipeline_env
        "README"       = local.pipeline_readme
      }
    }

    "streaming/ConfigMap/orders-pipeline-scripts" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata = {
        name      = "orders-pipeline-scripts"
        namespace = local.namespace
      }
      data = {
        "connector.sh"  = local.connector_script
        "enrichment.sh" = local.enrichment_script
        "rollup.sh"     = local.rollup_script
      }
    }

    "streaming/Deployment/orders-cdc-connector" = {
      apiVersion = "apps/v1"
      kind       = "Deployment"
      metadata = {
        name      = "orders-cdc-connector"
        namespace = local.namespace
        labels    = { app = "orders-cdc-connector" }
      }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "orders-cdc-connector" } }
        template = {
          metadata = { labels = { app = "orders-cdc-connector" } }
          spec = {
            containers = [
              {
                name            = "connector"
                image           = local.kafka_image
                imagePullPolicy = "IfNotPresent"
                command         = ["/bin/sh", "/scripts/connector.sh"]
                resources = {
                  requests = { cpu = "10m", memory = "32Mi" }
                  limits   = { memory = "64Mi" }
                }
                volumeMounts = [
                  { name = "config", mountPath = "/config" },
                  { name = "scripts", mountPath = "/scripts" },
                  { name = "state", mountPath = "/state" },
                ]
              },
            ]
            volumes = [
              { name = "config", configMap = { name = "orders-pipeline-config" } },
              { name = "scripts", configMap = { name = "orders-pipeline-scripts", defaultMode = 365 } },
              { name = "state", emptyDir = {} },
            ]
          }
        }
      }
    }

    "streaming/Deployment/orders-enrichment" = {
      apiVersion = "apps/v1"
      kind       = "Deployment"
      metadata = {
        name      = "orders-enrichment"
        namespace = local.namespace
        labels    = { app = "orders-enrichment" }
      }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "orders-enrichment" } }
        template = {
          metadata = { labels = { app = "orders-enrichment" } }
          spec = {
            containers = [
              {
                name            = "enrichment"
                image           = local.kafka_image
                imagePullPolicy = "IfNotPresent"
                command         = ["/bin/sh", "/scripts/enrichment.sh"]
                env = [
                  { name = "KAFKA_HEAP_OPTS", value = "-Xms32M -Xmx128M" },
                ]
                resources = {
                  requests = { cpu = "100m", memory = "512Mi" }
                  limits   = { memory = "896Mi" }
                }
                volumeMounts = [
                  { name = "config", mountPath = "/config" },
                  { name = "scripts", mountPath = "/scripts" },
                ]
              },
            ]
            volumes = [
              { name = "config", configMap = { name = "orders-pipeline-config" } },
              { name = "scripts", configMap = { name = "orders-pipeline-scripts", defaultMode = 365 } },
            ]
          }
        }
      }
    }

    "streaming/Deployment/orders-rollup" = {
      apiVersion = "apps/v1"
      kind       = "Deployment"
      metadata = {
        name      = "orders-rollup"
        namespace = local.namespace
        labels    = { app = "orders-rollup" }
      }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "orders-rollup" } }
        template = {
          metadata = { labels = { app = "orders-rollup" } }
          spec = {
            containers = [
              {
                name            = "rollup"
                image           = local.kafka_image
                imagePullPolicy = "IfNotPresent"
                command         = ["/bin/sh", "/scripts/rollup.sh"]
                env = [
                  { name = "KAFKA_HEAP_OPTS", value = "-Xms32M -Xmx128M" },
                ]
                resources = {
                  requests = { cpu = "100m", memory = "512Mi" }
                  limits   = { memory = "896Mi" }
                }
                volumeMounts = [
                  { name = "config", mountPath = "/config" },
                  { name = "scripts", mountPath = "/scripts" },
                ]
              },
            ]
            volumes = [
              { name = "config", configMap = { name = "orders-pipeline-config" } },
              { name = "scripts", configMap = { name = "orders-pipeline-scripts", defaultMode = 365 } },
            ]
          }
        }
      }
    }
  }
}
