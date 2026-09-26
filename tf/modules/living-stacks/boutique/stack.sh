#!/usr/bin/env bash
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# NS/SYSTEM/PROFILE are the multi-instance and load-variability parameters
# for this stack: NS is the target namespace, SYSTEM is a short instance
# label used on the namespace and every pod (living-stack=$SYSTEM,
# living-stack-component=boutique), PROFILE picks a boutique/profiles/*.json
# file that controls the bundled Locust loadgenerator's USERS and RATE. See
# README.md.
NS="${NS:-boutique}"
SYSTEM="${SYSTEM:-primary}"
PROFILE="${PROFILE:-calm}"
NAMESPACE="$NS"
# helm release name is derived from NS so multiple instances (e.g.
# boutique-a, boutique-b) can coexist in the same cluster, same as
# otel-demo/stack.sh.
RELEASE="boutique-${NS}"
LIVING_STACK_COMPONENT="boutique"

CHART_REF="oci://us-docker.pkg.dev/online-boutique-ci/charts/onlineboutique"
CHART_NAME="onlineboutique"
CHART_VERSION="0.10.6"

LOADGEN_NAME="loadgenerator"
PROBE_POD="boutique-probe"
PROBE_IMAGE="curlimages/curl:8.11.0"

usage() {
  cat <<'EOF'
Usage: stack.sh <command> <lane> [args]

Commands:
  up        gke                    bring the stack up
  down      gke                    tear the stack down
  status    gke                    print status of stack components
  verify    gke                    run smoke tests, prints PASS/FAIL per check

Env vars:
  NS              target namespace (default: boutique)
  SYSTEM          short instance label, used for living-stack=$SYSTEM on the
                  namespace and every pod (default: primary)
  PROFILE         load profile from profiles/*.json, controls the bundled
                  Locust loadgenerator's USERS/RATE (default: calm; also:
                  busy, rush)
  GKE_CONTEXT     override the detected kubectl context

This stack only deploys to GKE. The full demo with honest resource requests
wants real autoscaling (NAP), not a disposable dev cluster; see README.md.
EOF
}

log() { echo "[stack.sh] $*"; }

require_gke_context() {
  local ctx
  ctx="${GKE_CONTEXT:-$(kubectl config current-context)}"
  if [[ "$ctx" == kind-* ]]; then
    echo "refusing: context '$ctx' looks like a kind cluster, expected a GKE context" >&2
    echo "set GKE_CONTEXT env var or switch kubectl context to the target GKE cluster" >&2
    exit 1
  fi
  if [[ "$ctx" != "$(kubectl config current-context)" ]]; then
    kubectl config use-context "$ctx"
  fi
  log "using context: $ctx"
}

require_lane_gke() {
  local lane="$1"
  if [[ "$lane" != "gke" ]]; then
    echo "unsupported lane '$lane': this stack only deploys to gke" >&2
    exit 1
  fi
}

ensure_probe_pod() {
  if ! kubectl get pod "$PROBE_POD" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "creating probe pod $PROBE_POD"
    kubectl run "$PROBE_POD" -n "$NAMESPACE" --image="$PROBE_IMAGE" \
      --restart=Never --command \
      --labels="living-stack=${SYSTEM},living-stack-component=${LIVING_STACK_COMPONENT}" \
      -- sleep infinity >/dev/null
  fi
  # Keep kubectl's informational output off stdout: ensure_probe_pod is
  # called from inside command substitutions and any stray stdout here
  # would corrupt the captured response, same reasoning as otel-demo's
  # ensure_probe_pod.
  kubectl wait pod "$PROBE_POD" -n "$NAMESPACE" --for=condition=Ready --timeout=120s >/dev/null
}

probe_curl() {
  kubectl exec -n "$NAMESPACE" "$PROBE_POD" -- curl -sS "$@"
}

load_profile() {
  local profile_file="$SCRIPT_DIR/profiles/${PROFILE}.json"
  if [[ ! -f "$profile_file" ]]; then
    echo "unknown profile '$PROFILE' (no $profile_file)" >&2
    echo "available: $(ls "$SCRIPT_DIR/profiles" | sed 's/\.json$//' | tr '\n' ' ')" >&2
    exit 1
  fi
  LOADGEN_USERS="$(jq -r '.users' "$profile_file")"
  LOADGEN_RATE="$(jq -r '.rate' "$profile_file")"
  export LOADGEN_USERS LOADGEN_RATE
}

up_gke() {
  require_gke_context
  load_profile
  export LIVING_STACK="$SYSTEM" LIVING_STACK_COMPONENT LOADGEN_NAME

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$NAMESPACE" \
    "living-stack=${SYSTEM}" "living-stack-component=${LIVING_STACK_COMPONENT}" --overwrite
  kubectl annotate namespace "$NAMESPACE" \
    "living-stacks.boutique/profile=${PROFILE}" --overwrite >/dev/null

  log "installing $CHART_NAME $CHART_VERSION as release $RELEASE in ns $NAMESPACE (system=$SYSTEM, profile=$PROFILE: USERS=$LOADGEN_USERS RATE=$LOADGEN_RATE)"
  helm upgrade --install "$RELEASE" "$CHART_REF" \
    --version "$CHART_VERSION" \
    --namespace "$NAMESPACE" --create-namespace \
    -f "$SCRIPT_DIR/values.yaml" \
    --post-renderer "$SCRIPT_DIR/post-renderer.sh" \
    --timeout 15m

  ensure_probe_pod

  log "waiting for frontend rollout"
  kubectl rollout status "deployment/frontend" -n "$NAMESPACE" --timeout=900s

  log "waiting for loadgenerator rollout"
  kubectl rollout status "deployment/${LOADGEN_NAME}" -n "$NAMESPACE" --timeout=900s

  log "waiting for remaining deployments (this can take a while if NAP is scaling up nodes)"
  local deploys d
  deploys="$(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}')"
  for d in $deploys; do
    kubectl rollout status "deployment/$d" -n "$NAMESPACE" --timeout=900s || \
      echo "[stack.sh] warning: deployment/$d did not become ready in time" >&2
  done

  log "stack is up. run './stack.sh verify gke' to check health."
}

down_gke() {
  require_gke_context
  log "uninstalling helm release $RELEASE (namespace $NAMESPACE is left in place)"
  helm uninstall "$RELEASE" -n "$NAMESPACE" --wait --timeout 10m || true
  kubectl delete pod "$PROBE_POD" -n "$NAMESPACE" --ignore-not-found
}

status_gke() {
  require_gke_context
  echo "--- pods ---"
  kubectl get pods -n "$NAMESPACE" -o wide
  echo "--- deployments ---"
  kubectl get deployments -n "$NAMESPACE"
  echo "--- helm release ---"
  helm status "$RELEASE" -n "$NAMESPACE" 2>/dev/null | head -20
  echo
  echo "--- applied profile ---"
  kubectl get namespace "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.living-stacks\.boutique/profile}' 2>/dev/null || true
  echo
}

check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    FAILED=1
  fi
}

check_pods_ready() {
  local start now not_ready
  start="$(date +%s)"
  while true; do
    not_ready="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | \
      awk '$3 != "Running" && $3 != "Completed" && $3 != "Succeeded" {print}' || true)"
    not_ready="$(echo "$not_ready" | grep -v "^${PROBE_POD} " || true)"
    if [[ -z "$not_ready" ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > 120 )); then
      echo "  not ready:" >&2
      echo "$not_ready" >&2
      return 1
    fi
    sleep 5
  done
}

check_frontend_content() {
  ensure_probe_pod
  local code body
  code="$(probe_curl -o /dev/null -w '%{http_code}' "http://frontend:80/" 2>/dev/null || true)"
  if [[ "$code" != "200" ]]; then
    echo "  frontend returned HTTP '$code', expected 200" >&2
    return 1
  fi
  body="$(probe_curl "http://frontend:80/" 2>/dev/null || true)"
  if ! grep -q "Hot Products" <<< "$body"; then
    echo "  frontend response body did not contain 'Hot Products'" >&2
    return 1
  fi
  if ! grep -q "Sunglasses" <<< "$body"; then
    echo "  frontend response body did not contain the 'Sunglasses' product (id OLJCESPC7Z)" >&2
    return 1
  fi
}

# Parses the bundled Locust loadgenerator's periodic headless stats table,
# e.g.:
#   Type     Name             # reqs      # fails | ...
#   GET      /                     177     0(0.00%) | ...
#            Aggregated            207    30(14.49%) | ...
# and returns the "reqs" ($2) and "fails" ($3, parenthetical percent
# stripped) fields of the most recent line matching $1 (a fixed grep
# pattern, not a regex the loadgenerator can smuggle formatting into).
latest_locust_row() {
  local pattern="$1" logs line
  logs="$(kubectl logs -n "$NAMESPACE" -l app="$LOADGEN_NAME" --tail=500 --since=5m 2>/dev/null || true)"
  line="$(echo "$logs" | grep -F -- "$pattern" | tail -1 || true)"
  echo "$line"
}

check_loadgen_traffic() {
  local start now line reqs fails failpct
  start="$(date +%s)"
  while true; do
    line="$(latest_locust_row "Aggregated")"
    reqs="$(echo "$line" | awk '{print $2}')"
    fails="$(echo "$line" | awk '{print $3}' | grep -oE '^[0-9]+' || echo 0)"
    if [[ "$reqs" =~ ^[0-9]+$ ]] && (( reqs > 0 )); then
      failpct=$(( fails * 100 / reqs ))
      if (( failpct > 50 )); then
        echo "  Aggregated Locust failure rate too high (${failpct}%): $line" >&2
        return 1
      fi
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > 150 )); then
      echo "  no nonzero 'Aggregated' Locust stats line in load-generator logs within 150s (last row: ${line:-<none>})" >&2
      return 1
    fi
    sleep 10
  done
}

check_checkout_flow() {
  local start now line reqs fails successes
  start="$(date +%s)"
  while true; do
    line="$(latest_locust_row "/cart/checkout")"
    if [[ -n "$line" ]]; then
      reqs="$(echo "$line" | awk '{print $3}')"
      fails="$(echo "$line" | awk '{print $4}' | grep -oE '^[0-9]+' || echo 0)"
      if [[ "$reqs" =~ ^[0-9]+$ ]] && (( reqs > 0 )); then
        successes=$(( reqs - fails ))
        if (( successes > 0 )); then
          return 0
        fi
      fi
    fi
    now="$(date +%s)"
    if (( now - start > 150 )); then
      echo "  no successful POST /cart/checkout evidence in load-generator logs within 150s (last row: ${line:-<none>})" >&2
      return 1
    fi
    sleep 10
  done
}

check_labels_complete() {
  local total labeled
  total="$(kubectl get pod -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)"
  labeled="$(kubectl get pod -n "$NAMESPACE" -l "living-stack-component=${LIVING_STACK_COMPONENT}" --no-headers 2>/dev/null | wc -l)"
  if [[ "$total" -eq 0 ]]; then
    echo "  no pods found in $NAMESPACE" >&2
    return 1
  fi
  if [[ "$total" != "$labeled" ]]; then
    echo "  pod count ($total) does not match living-stack-component=${LIVING_STACK_COMPONENT} labeled pod count ($labeled)" >&2
    return 1
  fi
}

verify_gke() {
  require_gke_context
  FAILED=0
  check "all pods Ready/Completed in $NAMESPACE" check_pods_ready
  check "frontend responds 200 with real product content (Hot Products / Sunglasses)" check_frontend_content
  check "load generator producing traffic (Locust stats, low failure rate)" check_loadgen_traffic
  check "checkout flow completes end to end (Locust POST /cart/checkout succeeding)" check_checkout_flow
  check "every pod in $NAMESPACE carries living-stack-component=${LIVING_STACK_COMPONENT}" check_labels_complete
  return "$FAILED"
}

main() {
  local cmd="${1:-}" lane="${2:-}"
  case "$cmd" in
    up)
      require_lane_gke "$lane"
      up_gke
      ;;
    down)
      require_lane_gke "$lane"
      down_gke
      ;;
    status)
      require_lane_gke "$lane"
      status_gke
      ;;
    verify)
      require_lane_gke "$lane"
      verify_gke
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
