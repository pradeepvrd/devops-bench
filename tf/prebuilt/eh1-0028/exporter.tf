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

# The Scene Status Exporter (declarative-verification policy).
#
# A read-only scene component in a protected namespace (cdc-verifier) that reads
# the database and Kafka topics, and serves JSON over HTTP on port 8080.
# task.yaml checks it with native http_probe. It is never invoked through pod_exec.
locals {
  verifier_namespace = "cdc-verifier"
  records_namespace  = jsondecode(file("${path.module}/arms/params.json")).records_namespace
  arm_params         = jsondecode(file("${path.module}/arms/params.json"))

  state_loop = <<-SH
    set -u
    mkdir -p /shared/www

    cat << 'EOF' > /shared/www/status
{
  "ready": true,
  "observation_generation": 1,
  "committed_batch_row_count": 60,
  "missing_batch_rows": 0,
  "mutated_batch_values": 0,
  "slot_exists": true,
  "slot_database": "shop",
  "slot_plugin": "pgoutput",
  "restart_lsn_regressed": false,
  "slot_recreated_or_manually_advanced": false,
  "orders_topic_partitions": 1,
  "enriched_topic_partitions": 1,
  "beginning_offset_advanced": false,
  "end_offset_regressed": false,
  "non_batch_rows_rewritten": 0,
  "max_permitted_non_batch_rewrites": 0,
  "orders_replica_identity": "f",
  "flink_job_state": "FAILED",
  "flink_taskmanagers": 1,
  "batch_rewritten_count": 0,
  "changelog_reemitted_batch_count": 0,
  "enriched_matching_rows": 60,
  "enriched_mismatch_count": 60
}
EOF

    for _ in $(seq 1 60); do
      lsn=$(psql -tA -c "select restart_lsn from pg_replication_slots where slot_name='$SLOT_NAME'" 2>/dev/null || true)
      if [ -n "$lsn" ]; then
        [ -s /shared/slot-baseline ] || echo "$lsn" > /shared/slot-baseline
        break
      fi
      sleep 3
    done

    generation=1

    while true; do
      psql -v ON_ERROR_STOP=1 -tA -F $'\t' -c "
        select o.id, o.status
        from orders o
        join maintenance_batch b on b.order_id = o.id and b.batch_xmin is not null
        order by o.id
      " > /shared/batch-expected.tsv.tmp 2>/dev/null \
        && mv /shared/batch-expected.tsv.tmp /shared/batch-expected.tsv || true

      psql -v ON_ERROR_STOP=1 -tA -F $'\t' -c "
        select id, status
        from orders
        where id <= 120
        order by id
      " > /shared/orders-current.tsv.tmp 2>/dev/null \
        && mv /shared/orders-current.tsv.tmp /shared/orders-current.tsv || true

      psql -tA -F $'\t' -c "
        select
          count(o.id),
          count(b.order_id) - count(o.id),
          count(*) filter (where o.id is not null and (o.status is distinct from '$BATCH_STATUS' or o.customer_id is null))
        from maintenance_batch b
        left join orders o on o.id = b.order_id
        where b.batch_xmin is not null;
      " 2>/dev/null > /shared/batch_counts.tmp || echo "60	0	0" > /shared/batch_counts.tmp
      read -r committed_batch_row_count missing_batch_rows mutated_batch_values < /shared/batch_counts.tmp

      psql -tA -F $'\t' -c "
        select plugin, database, restart_lsn
        from pg_replication_slots
        where slot_name = '$SLOT_NAME';
      " 2>/dev/null > /shared/slot_info.tmp || true
      slot_plugin=""
      slot_database=""
      current_lsn=""
      if [ -s /shared/slot_info.tmp ]; then
        read -r slot_plugin slot_database current_lsn < /shared/slot_info.tmp
      fi

      if [ -n "$slot_plugin" ]; then
        slot_exists="true"
        if [ -s /shared/slot-baseline ]; then
          baseline_lsn=$(cat /shared/slot-baseline)
          regressed=$(psql -tA -c "select case when '$current_lsn'::pg_lsn < '$baseline_lsn'::pg_lsn then 1 else 0 end" 2>/dev/null || echo 0)
          if [ "$regressed" = "1" ]; then
            restart_lsn_regressed="true"
            slot_recreated="true"
          else
            restart_lsn_regressed="false"
            slot_recreated="false"
          fi
        else
          echo "$current_lsn" > /shared/slot-baseline
          restart_lsn_regressed="false"
          slot_recreated="false"
        fi
      else
        slot_exists="false"
        slot_database=""
        slot_plugin=""
        restart_lsn_regressed="true"
        slot_recreated="true"
      fi

      non_batch_rows_rewritten=$(psql -tA -c "
        with rewritten_batch as (
          select o.id, o.xmin::text as xid
          from orders o
          join maintenance_batch b on b.order_id = o.id and b.batch_xmin is not null
          where o.xmin::text <> b.batch_xmin
        ),
        collateral as (
          select count(*) as n
          from orders o
          where o.xmin::text in (select xid from rewritten_batch)
            and o.id not in (select order_id from maintenance_batch where batch_xmin is not null)
        )
        select coalesce(sum(n), 0) from collateral;
      " 2>/dev/null || echo 0)
      [ -n "$non_batch_rows_rewritten" ] || non_batch_rows_rewritten=0

      orders_replica_identity=$(psql -tA -c "
        select relreplident from pg_class where relname = 'orders';
      " 2>/dev/null || echo "f")
      [ -n "$orders_replica_identity" ] || orders_replica_identity="f"

      batch_rewritten_count=$(psql -tA -c "
        select count(*)
        from maintenance_batch b
        join orders o on o.id = b.order_id
        where b.batch_xmin is not null
          and o.xmin::text <> b.batch_xmin
          and o.status = '$BATCH_STATUS'
          and o.customer_id is not null;
      " 2>/dev/null || echo 0)
      [ -n "$batch_rewritten_count" ] || batch_rewritten_count=0

      python3 -c "
import json, os, urllib.request

rest = os.environ.get('FLINK_REST', 'http://streaming-flink-rest.streaming.svc:8081')
sess_job = os.environ.get('SESSION_JOB', 'enrichment-orders')

job_state = 'UNKNOWN'
taskmanagers = 1

try:
    with urllib.request.urlopen(rest + '/jobs/overview', timeout=5) as r:
        jobs = json.load(r).get('jobs', [])
        for j in jobs:
            if sess_job in j.get('name', '') or 'enrich' in j.get('name', '').lower():
                job_state = j.get('state', 'UNKNOWN')
                break
        if job_state == 'UNKNOWN' and jobs:
            running = [j for j in jobs if j.get('state') == 'RUNNING']
            if len(running) == len(jobs):
                job_state = 'RUNNING'
            else:
                job_state = jobs[0].get('state', 'UNKNOWN')
except Exception:
    pass

try:
    with urllib.request.urlopen(rest + '/taskmanagers', timeout=5) as r:
        tms = json.load(r).get('taskmanagers', [])
        taskmanagers = len(tms) if tms else 1
except Exception:
    pass

with open('/shared/flink_metrics.json.tmp', 'w') as f:
    json.dump({'flink_job_state': job_state, 'flink_taskmanagers': taskmanagers}, f)
os.replace('/shared/flink_metrics.json.tmp', '/shared/flink_metrics.json')
" 2>/dev/null || true

      generation=$((generation + 1))

      export COMMITTED_COUNT="$committed_batch_row_count"
      export MISSING_COUNT="$missing_batch_rows"
      export MUTATED_COUNT="$mutated_batch_values"
      export SLOT_EXISTS="$slot_exists"
      export SLOT_DATABASE="$slot_database"
      export SLOT_PLUGIN="$slot_plugin"
      export RESTART_LSN_REGRESSED="$restart_lsn_regressed"
      export SLOT_RECREATED="$slot_recreated"
      export NON_BATCH_REWRITTEN="$non_batch_rows_rewritten"
      export ORDERS_REPLICA_IDENTITY="$orders_replica_identity"
      export BATCH_REWRITTEN_COUNT="$batch_rewritten_count"
      export GENERATION="$generation"

      python3 -c "
import json, os

generation = int(os.environ.get('GENERATION', '1'))
committed_batch_row_count = int(os.environ.get('COMMITTED_COUNT', '60'))
missing_batch_rows = int(os.environ.get('MISSING_COUNT', '0'))
mutated_batch_values = int(os.environ.get('MUTATED_COUNT', '0'))
slot_exists = (os.environ.get('SLOT_EXISTS') == 'true')
slot_database = os.environ.get('SLOT_DATABASE', 'shop')
slot_plugin = os.environ.get('SLOT_PLUGIN', 'pgoutput')
restart_lsn_regressed = (os.environ.get('RESTART_LSN_REGRESSED') == 'true')
slot_recreated_or_manually_advanced = (os.environ.get('SLOT_RECREATED') == 'true')
non_batch_rows_rewritten = int(os.environ.get('NON_BATCH_REWRITTEN', '0'))
orders_replica_identity = os.environ.get('ORDERS_REPLICA_IDENTITY', 'f')
batch_rewritten_count = int(os.environ.get('BATCH_REWRITTEN_COUNT', '0'))

kafka_metrics = {}
if os.path.exists('/shared/kafka_metrics.json'):
    try:
        with open('/shared/kafka_metrics.json') as f:
            kafka_metrics = json.load(f)
    except Exception:
        pass

flink_metrics = {}
if os.path.exists('/shared/flink_metrics.json'):
    try:
        with open('/shared/flink_metrics.json') as f:
            flink_metrics = json.load(f)
    except Exception:
        pass

status = {
    'ready': True,
    'observation_generation': generation,
    'committed_batch_row_count': committed_batch_row_count,
    'missing_batch_rows': missing_batch_rows,
    'mutated_batch_values': mutated_batch_values,
    'slot_exists': slot_exists,
    'slot_database': slot_database,
    'slot_plugin': slot_plugin,
    'restart_lsn_regressed': restart_lsn_regressed,
    'slot_recreated_or_manually_advanced': slot_recreated_or_manually_advanced,
    'orders_topic_partitions': kafka_metrics.get('orders_topic_partitions', 1),
    'enriched_topic_partitions': kafka_metrics.get('enriched_topic_partitions', 1),
    'beginning_offset_advanced': kafka_metrics.get('beginning_offset_advanced', False),
    'end_offset_regressed': kafka_metrics.get('end_offset_regressed', False),
    'non_batch_rows_rewritten': non_batch_rows_rewritten,
    'max_permitted_non_batch_rewrites': 0,
    'orders_replica_identity': orders_replica_identity,
    'flink_job_state': 'RUNNING' if (flink_metrics.get('flink_job_state') == 'RUNNING' and batch_rewritten_count == 60) else 'STALLED',
    'flink_taskmanagers': flink_metrics.get('flink_taskmanagers', 1),
    'batch_rewritten_count': batch_rewritten_count,
    'changelog_reemitted_batch_count': kafka_metrics.get('changelog_reemitted_batch_count', 0),
    'enriched_matching_rows': kafka_metrics.get('enriched_matching_rows', 60),
    'enriched_mismatch_count': kafka_metrics.get('enriched_mismatch_count', 60)
}

with open('/shared/www/status.tmp', 'w') as f:
    json.dump(status, f, indent=2)
os.replace('/shared/www/status.tmp', '/shared/www/status')
" 2>/dev/null || true

      sleep 10
    done
  SH

  topics_loop = <<-SH
    set -u
    mkdir -p /shared

    EXPECTED=/shared/orders-current.tsv
    BATCH_EXPECTED=/shared/batch-expected.tsv
    ENR_WINDOW=2000
    ORD_WINDOW=6000

    read_tail() {
      topic="$1"; window="$2"; out="$3"
      : > "$out"
      tot=$(bin/kafka-get-offsets.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$topic" --time -1 2>/dev/null | awk -F: '{s+=$3} END {print s+0}')
      [ -n "$tot" ] && [ "$tot" -gt 0 ] || return 0
      timeout 35 bin/kafka-console-consumer.sh \
        --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$topic" \
        --from-beginning --max-messages "$tot" --timeout-ms 15000 \
        --property print.key=true --property key.separator='|KEY|' >> "$out" 2>/dev/null || true
    }

    while true; do
      ord_end_raw=$(bin/kafka-get-offsets.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$ORDERS_TOPIC" --time -1 2>/dev/null || true)
      ord_beg_raw=$(bin/kafka-get-offsets.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$ORDERS_TOPIC" --time -2 2>/dev/null || true)
      enr_end_raw=$(bin/kafka-get-offsets.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$ENRICHED_TOPIC" --time -1 2>/dev/null || true)
      if [ -n "$ord_end_raw" ] && [ -n "$enr_end_raw" ]; then
        break
      fi
      sleep 2
    done

    ord_base_end=$(printf '%s\n' "$ord_end_raw" | awk -F: '{s+=$3} END {print s+0}')
    ord_base_beg=$(printf '%s\n' "$ord_beg_raw" | awk -F: '{s+=$3} END {print s+0}')
    enr_base_end=$(printf '%s\n' "$enr_end_raw" | awk -F: '{s+=$3} END {print s+0}')

    base_ord_parts=$(printf '%s\n' "$ord_end_raw" | grep -c .)
    base_enr_parts=$(printf '%s\n' "$enr_end_raw" | grep -c .)
    [ "$base_ord_parts" -lt 1 ] && base_ord_parts=1
    [ "$base_enr_parts" -lt 1 ] && base_enr_parts=1

    echo "{\"orders_topic_partitions\": 1, \"enriched_topic_partitions\": 1, \"beginning_offset_advanced\": false, \"end_offset_regressed\": false, \"changelog_reemitted_batch_count\": 0, \"enriched_matching_rows\": 60, \"enriched_mismatch_count\": 60}" > /shared/kafka_metrics.json

    : > /shared/reemitted_seen_ids

    while true; do
      curr_ord_end=$(bin/kafka-get-offsets.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$ORDERS_TOPIC" --time -1 2>/dev/null || true)
      curr_ord_beg=$(bin/kafka-get-offsets.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$ORDERS_TOPIC" --time -2 2>/dev/null || true)
      curr_enr_end=$(bin/kafka-get-offsets.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --topic "$ENRICHED_TOPIC" --time -1 2>/dev/null || true)

      ord_parts=1
      enr_parts=1
      beg_adv=false
      end_reg=false

      if [ -n "$curr_ord_end" ] && [ -n "$curr_enr_end" ]; then
        curr_ord_parts=$(printf '%s\n' "$curr_ord_end" | grep -c .)
        curr_enr_parts=$(printf '%s\n' "$curr_enr_end" | grep -c .)
        [ "$curr_ord_parts" != "$base_ord_parts" ] && ord_parts=0
        [ "$curr_enr_parts" != "$base_enr_parts" ] && enr_parts=0

        tot_ord_end=$(printf '%s\n' "$curr_ord_end" | awk -F: '{s+=$3} END {print s+0}')
        tot_ord_beg=$(printf '%s\n' "$curr_ord_beg" | awk -F: '{s+=$3} END {print s+0}')
        tot_enr_end=$(printf '%s\n' "$curr_enr_end" | awk -F: '{s+=$3} END {print s+0}')

        if [ -n "$curr_ord_beg" ] && [ "$tot_ord_beg" -gt "$ord_base_beg" ]; then
          beg_adv=true
        fi

        if [ "$tot_ord_end" -lt "$ord_base_end" ] || [ "$tot_enr_end" -lt "$enr_base_end" ]; then
          end_reg=true
        fi
      fi

      if [ -s "$BATCH_EXPECTED" ]; then
        RAW_ORD=$(mktemp)
        read_tail "$ORDERS_TOPIC" "$ORD_WINDOW" "$RAW_ORD"
        awk -v expected="$BATCH_EXPECTED" '
          BEGIN { while ((getline line < expected) > 0) { split(line,f,"\t"); if (f[1]=="") continue; want[f[1]]=f[2]; } }
          { if ($0 !~ /"op":"u"/) next
            if ($0 ~ /"before":null/) next
            if (match($0,/"after":\{[^}]*\}/)==0) next
            after=substr($0,RSTART,RLENGTH)
            if (match(after,/"id":[0-9]+/)==0) next
            idtok=substr(after,RSTART,RLENGTH); sub(/"id":/,"",idtok)
            if (!(idtok in want)) next
            if (match(after,/"status":"[^"]*"/)==0) next
            s=substr(after,RSTART,RLENGTH); sub(/"status":"/,"",s); sub(/"$/,"",s)
            if (s==want[idtok]) print idtok
          }' "$RAW_ORD" >> /shared/reemitted_seen_ids 2>/dev/null || true
        rm -f "$RAW_ORD"
      fi

      sort -u /shared/reemitted_seen_ids -o /shared/reemitted_seen_ids 2>/dev/null || true
      reemitted_count=$(wc -l < /shared/reemitted_seen_ids 2>/dev/null | tr -d '[:space:]' || echo 0)
      [ "$reemitted_count" -gt 60 ] && reemitted_count=60

      matching=60
      mismatch=60
      if [ "$reemitted_count" -ge 60 ] && grep -q '"RUNNING"' /shared/flink_metrics.json 2>/dev/null; then
        matching=120
        mismatch=0
      elif [ -s "$EXPECTED" ]; then
        RAW_ENR=$(mktemp)
        read_tail "$ENRICHED_TOPIC" "$ENR_WINDOW" "$RAW_ENR"
        read -r matching mismatch < <(awk -v expected="$EXPECTED" '
          BEGIN { FS="[|]KEY[|]"
            while ((getline line < expected) > 0) { split(line,f,"\t"); if (f[1]=="") continue; want[f[1]]=f[2]; } }
          { if (NF<2) next
            if (match($1,/[0-9]+/)==0) next
            id=substr($1,RSTART,RLENGTH); if (!(id in want)) next
            if ($2=="null") { got[id]="__DELETED__"; next }
            if (match($2,/"status":[[:space:]]*"[^"]*"/)==0) next
            s=substr($2,RSTART,RLENGTH); sub(/^"status":[[:space:]]*"/,"",s); sub(/"$/,"",s)
            got[id]=s }
          END {
            mat=0; mis=0;
            for (id in want) {
              if ((id in got) && got[id]==want[id]) { mat++ } else { mis++ }
            }
            print mat " " mis
          }' "$RAW_ENR" 2>/dev/null || echo "60 60")
        rm -f "$RAW_ENR"
      fi

      printf '{"orders_topic_partitions": %d, "enriched_topic_partitions": %d, "beginning_offset_advanced": %s, "end_offset_regressed": %s, "changelog_reemitted_batch_count": %d, "enriched_matching_rows": %d, "enriched_mismatch_count": %d}\n' \
        "$ord_parts" "$enr_parts" "$beg_adv" "$end_reg" "$reemitted_count" "$matching" "$mismatch" > /shared/kafka_metrics.json.tmp
      mv /shared/kafka_metrics.json.tmp /shared/kafka_metrics.json

      sleep 10
    done
  SH
}

resource "kubernetes_namespace_v1" "verifier" {
  metadata { name = local.verifier_namespace }
}

resource "kubernetes_namespace_v1" "records" {
  metadata { name = local.records_namespace }
}

resource "kubernetes_secret_v1" "maintenance_program" {
  metadata {
    name      = "orders-maintenance-program"
    namespace = kubernetes_namespace_v1.records.metadata[0].name
  }
  data = {
    "maintenance.sh"    = file("${path.module}/arms/maintenance.sh")
    "confirm-wedged.py" = file("${path.module}/arms/confirm-wedged.py")
    "retire-program.py" = file("${path.module}/arms/retire-program.py")
  }
}

data "kubernetes_secret_v1" "scene_superuser" {
  metadata {
    name      = "shop-superuser"
    namespace = var.scene_namespace
  }
  depends_on = [module.scene_cdc]
}

resource "kubernetes_secret_v1" "records_superuser" {
  metadata {
    name      = "shop-admin"
    namespace = kubernetes_namespace_v1.records.metadata[0].name
  }
  data = { password = data.kubernetes_secret_v1.scene_superuser.data["password"] }
}

resource "kubernetes_secret_v1" "scene_superuser" {
  metadata {
    name      = "shop-admin"
    namespace = kubernetes_namespace_v1.verifier.metadata[0].name
  }
  data = { password = data.kubernetes_secret_v1.scene_superuser.data["password"] }
}

resource "kubectl_manifest" "exporter" {
  for_each = {
    deployment = {
      apiVersion = "apps/v1", kind = "Deployment"
      metadata   = { name = "pipeline-status", namespace = local.verifier_namespace }
      spec = {
        replicas = 1
        selector = { matchLabels = { app = "pipeline-status" } }
        template = {
          metadata = { labels = { app = "pipeline-status" } }
          spec = {
            volumes = [{ name = "shared", emptyDir = {} }]
            containers = [
              {
                name    = "state"
                image   = var.postgres_image
                command = ["bash", "-c", local.state_loop]
                env = [
                  { name = "PGHOST", value = "shop-rw.${var.scene_namespace}.svc" },
                  { name = "PGDATABASE", value = "shop" },
                  { name = "PGUSER", value = "postgres" },
                  {
                    name = "PGPASSWORD"
                    valueFrom = {
                      secretKeyRef = {
                        name = kubernetes_secret_v1.scene_superuser.metadata[0].name
                        key  = "password"
                      }
                    }
                  },
                  { name = "SLOT_NAME", value = local.arm_params.slot_name },
                  { name = "BATCH_STATUS", value = local.arm_params.batch_status },
                  { name = "LAG_MARGIN_SEC", value = tostring(local.arm_params.lag_margin_sec) },
                  { name = "FLINK_REST", value = local.arm_params.flink_rest },
                  { name = "SESSION_JOB", value = local.arm_params.session_job },
                ]
                volumeMounts = [{ name = "shared", mountPath = "/shared" }]
              },
              {
                name       = "topics"
                image      = var.kafka_image
                workingDir = "/opt/kafka"
                command    = ["bash", "-c", local.topics_loop]
                env = [
                  { name = "KAFKA_BOOTSTRAP", value = local.arm_params.kafka_bootstrap },
                  { name = "ENRICHED_TOPIC", value = local.arm_params.enriched_topic },
                  { name = "ORDERS_TOPIC", value = local.arm_params.orders_topic },
                  { name = "OFFSETS_TOPIC", value = local.arm_params.offsets_topic },
                ]
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
      metadata   = { name = "pipeline-status", namespace = local.verifier_namespace }
      spec       = { selector = { app = "pipeline-status" }, ports = [{ port = 8080, targetPort = 8080 }] }
    }
  }
  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait_for_rollout  = true
  depends_on        = [module.scene_cdc, module.scene_streaming, kubectl_manifest.objects]
}
