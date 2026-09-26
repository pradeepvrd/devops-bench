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

# Helm post-renderer for the onlineboutique chart. Reads the fully rendered
# manifest on stdin, patches it, writes the result to stdout (helm's
# post-renderer contract). Four independent patches:
#
# 1. Injects living-stack=$LIVING_STACK and
#    living-stack-component=$LIVING_STACK_COMPONENT into every Deployment's
#    pod template labels (spec.template.metadata.labels). Why a
#    post-renderer instead of a values key, the way otel-demo/ does it: the
#    onlineboutique chart (0.10.6) has no podLabels-equivalent values key
#    anywhere, checked against its shipped values.yaml and templates/*.yaml,
#    not guessed. Every Deployment's `app: <name>` label is a hardcoded
#    literal in its template, same as the loadgenerator's USERS/RATE env
#    values below. This only ever writes spec.template.metadata.labels, it
#    never touches spec.selector.matchLabels, so no Deployment's ability to
#    find its own pods changes.
#
# 2. Patches the loadgenerator Deployment's USERS and RATE container env
#    values to the active PROFILE's numbers. Same reason: the chart
#    hardcodes `USERS: "10"` / `RATE: "1"` as template literals in
#    templates/loadgenerator.yaml, not as values.yaml keys, so `helm --set`
#    cannot reach them.
#
# 3. Relaxes the emailservice Deployment's liveness/readiness probe timing.
#    Same reason: templates/emailservice.yaml hardcodes both probes with no
#    values.yaml key to reach them. Python gRPC cold start exceeds the
#    upstream 0s-delay 1s-timeout probes under the 200m CPU limit on
#    e2-standard-4; give it 20s and a 3s timeout. Scoped to the emailservice
#    Deployment only; periodSeconds and failureThreshold are left as shipped.
#
# 4. Caps the redis-cart Deployment's redis container at a fixed maxmemory
#    so the P-051 redis-cart-fill bench-fault primitive has a bounded target
#    to fill toward (it fills to 85% of `INFO memory`'s maxmemory field and
#    refuses if maxmemory is unconfigured, i.e. unlimited). Same reason as
#    the other patches: templates/cartservice.yaml ships the redis
#    container with no `args`/`command` and no values.yaml key to reach it,
#    so it runs with maxmemory unset (unlimited). Sets `--maxmemory 64mb
#    --maxmemory-policy noeviction`: noeviction is redis's own default
#    policy, stated explicitly here so writes deterministically fail with
#    OOM once the cap is hit, rather than silently evicting keys, which is
#    the failure symptom P-051 depends on. Appends to any existing `args`
#    instead of replacing it, and skips flags already present, so re-running
#    this post-renderer against already-patched output does not duplicate
#    them. The chart's stock redis-cart memory limit (256Mi, see
#    values.yaml) already comfortably covers 64mb of data plus redis
#    overhead, so resources are left untouched.
#
# Env vars read (set by stack.sh before invoking `helm ... --post-renderer
# post-renderer.sh`):
#   LIVING_STACK            value for the living-stack pod label (=$SYSTEM)
#   LIVING_STACK_COMPONENT  value for the living-stack-component pod label (boutique)
#   LOADGEN_NAME            name of the loadgenerator Deployment (loadgenerator)
#   LOADGEN_USERS           USERS env value to set on its main container
#   LOADGEN_RATE            RATE env value to set on its main container
#
# strenv(...) (not env(...)) is used throughout so numeric-looking values
# like LOADGEN_USERS are written back as YAML strings, matching the
# container env schema (a bare `25` would round-trip as a YAML integer and
# fail Kubernetes API validation for a string field).

yq eval '
  with(select(.kind == "Deployment");
    .spec.template.metadata.labels["living-stack"] = strenv(LIVING_STACK) |
    .spec.template.metadata.labels["living-stack-component"] = strenv(LIVING_STACK_COMPONENT)
  ) |
  with(select(.kind == "Deployment" and .metadata.name == strenv(LOADGEN_NAME));
    (.spec.template.spec.containers[] | select(.name == "main") | .env[] | select(.name == "USERS") | .value) = strenv(LOADGEN_USERS) |
    (.spec.template.spec.containers[] | select(.name == "main") | .env[] | select(.name == "RATE") | .value) = strenv(LOADGEN_RATE)
  ) |
  with(select(.kind == "Deployment" and .metadata.name == "emailservice");
    .spec.template.spec.containers[].livenessProbe.initialDelaySeconds = 20 |
    .spec.template.spec.containers[].livenessProbe.timeoutSeconds = 3 |
    .spec.template.spec.containers[].readinessProbe.initialDelaySeconds = 20 |
    .spec.template.spec.containers[].readinessProbe.timeoutSeconds = 3
  ) |
  with(select(.kind == "Deployment" and .metadata.name == "redis-cart");
    (.spec.template.spec.containers[] | select(.name == "redis")) |= (
      (.args // []) as $existing |
      .args = ($existing + (["--maxmemory", "64mb", "--maxmemory-policy", "noeviction"] - $existing))
    )
  )
' -
