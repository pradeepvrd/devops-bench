#!/bin/sh
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

# Nightly (or on-demand) per-topic retention governance attestation.
#
# Reads each configured topic's *effective*, broker-side retention.ms by
# exec-ing into a live broker pod and running that pod's own bundled
# kafka-configs.sh -- never the KafkaTopic CR's spec. The Topic Operator
# owns and reconciles the CR's spec; a topic-scoped override can still
# outrank the broker/cluster-wide defaults every other panel reads, which is
# exactly the class of drift this attestation exists to catch (see
# factory-303/catalog/tasks/S-020/story.yaml's chain). Reading the CR
# instead of the broker would make this script agree with the very drift it
# is supposed to notice.
set -eu

: "${NAMESPACE:?NAMESPACE is required}"
: "${KAFKA_CLUSTER_NAME:=kafka}"
: "${BROKER_POOL_LABEL:=dual-role}"
: "${TOPIC_RETENTION_POLICY:?TOPIC_RETENTION_POLICY is required (comma-separated topic=retention_ms pairs)}"
: "${RESULT_CONFIGMAP:=governance-attestation-result}"

broker_pod=$(kubectl get pods -n "$NAMESPACE" \
  -l "strimzi.io/cluster=${KAFKA_CLUSTER_NAME},strimzi.io/pool-name=${BROKER_POOL_LABEL}" \
  -o jsonpath='{.items[0].metadata.name}')

if [ -z "$broker_pod" ]; then
  echo "governance-attestation: no broker pod found for cluster ${KAFKA_CLUSTER_NAME}, pool ${BROKER_POOL_LABEL}" >&2
  exit 1
fi

failing=""
checked=""

saved_ifs=$IFS
IFS=,
for pair in $TOPIC_RETENTION_POLICY; do
  IFS=$saved_ifs
  topic=${pair%%=*}
  expected=${pair#*=}

  actual=$(kubectl exec -n "$NAMESPACE" "$broker_pod" -- \
    /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
    --describe --entity-type topics --entity-name "$topic" 2>/dev/null \
    | grep -oE 'retention\.ms=-?[0-9]+' | head -n1 | cut -d= -f2) || actual=""

  checked="$checked $topic"
  if [ "$actual" != "$expected" ]; then
    failing="$failing $topic"
  fi
  IFS=,
done
IFS=$saved_ifs

status="pass"
if [ -n "$failing" ]; then
  status="fail"
fi

checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

kubectl create configmap "$RESULT_CONFIGMAP" -n "$NAMESPACE" \
  --from-literal=status="$status" \
  --from-literal=checked_at="$checked_at" \
  --from-literal=failing_topics="$(echo "$failing" | sed 's/^ *//')" \
  --from-literal=checked_topics="$(echo "$checked" | sed 's/^ *//')" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "governance-attestation: status=${status} failing='${failing}'"
