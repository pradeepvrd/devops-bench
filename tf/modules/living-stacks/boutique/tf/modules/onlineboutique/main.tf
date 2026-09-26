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

# The onlineboutique chart (helm, native fit) rendered client-side with
# `data.helm_template`, patched with kustomize instead of
# `../../post-renderer.sh`'s bash+yq post-renderer, then applied with
# `kubectl apply -k` (no native Terraform resource submits a kustomization,
# same "null_resource + kubectl" precedent as every other CR/kustomize step
# in this codebase). This is a deliberate "render, patch, apply" pipeline,
# not a `helm_release` install: `helm_release` has no post-render hook to
# express `post-renderer.sh` through, and the alternative of installing via
# `helm_release` unpatched and layering a second reconciling patch step on
# top would leave a window where the chart's own (unpatched) probe timing
# and label state briefly exists in the cluster. Rendering, patching, then
# submitting the already-patched manifest in one `kubectl apply` avoids that
# window entirely.
#
# Four patches, applied via kustomize instead of yq, same fields
# `../../post-renderer.sh` touches and for the same reasons documented in its
# header (the chart has no values key to reach any of them):
#
#   1. living-stack / living-stack-component labels on every Deployment's
#      *pod template* labels only (a JSON6902 patch targeting kind: Deployment
#      broadcasts to all 12), never spec.selector.matchLabels -- verified
#      locally against a real `helm template` render of this chart version
#      before wiring this in: every Deployment's matchLabels is untouched by
#      building this kustomization script and diffing selectors before/after.
#   2. the loadgenerator Deployment's `main` container USERS/RATE env values,
#      via a strategic-merge patch scoped with `target: {kind: Deployment,
#      name: loadgenerator}` (kustomize merges container/env lists by their
#      own `name` mergeKey, the same precision the original yq expression
#      has). Values are always double-quoted string literals in the patch
#      (see templates/kustomization.yaml.tftpl), the same reason
#      post-renderer.sh uses yq's strenv() over env(): a bare `25` would
#      round-trip as a YAML integer and fail Kubernetes API validation for a
#      string field. Verified locally: kustomize preserves the quoting,
#      round-trips as a YAML string.
#   3. the emailservice Deployment's `server` container liveness/readiness
#      probe timing (initialDelaySeconds/timeoutSeconds only; periodSeconds
#      and failureThreshold are left as shipped, same as post-renderer.sh).
#   4. the redis-cart Deployment's `redis` container `args`
#      (`--maxmemory 64mb --maxmemory-policy noeviction`). Unlike
#      post-renderer.sh, which appends to any existing args and skips flags
#      already present so a *repeated CLI post-renderer run against
#      already-patched output* doesn't duplicate them, this module always
#      patches a *fresh* `helm template` render (never a previously-patched
#      manifest), so there is no existing-args state to merge around; a
#      plain strategic-merge args patch is the equivalent, not a
#      simplification of the original's safety behavior.
#
# What this pipeline does NOT reproduce: an actual Helm release. Since this
# never runs `helm install`/`helm upgrade`, the objects it applies carry none
# of Helm 3's own automatic ownership markers (`meta.helm.sh/release-name`,
# `meta.helm.sh/release-namespace` annotations, `app.kubernetes.io/managed-by:
# Helm` label) -- confirmed this chart's own templates set none of these
# themselves (no `.Release.Service` reference anywhere in templates/), so
# they exist only when Helm's own install/upgrade engine adds them, which
# this module's `kubectl apply -k` path never invokes. `helm list -n
# <namespace>` and `helm status` will show nothing for a stack brought up
# this way, and `helm uninstall` cannot remove it (this module's own
# destroy-time provisioner, `kubectl delete -k`, is the only way). The Pod/
# Deployment/Service specs themselves are otherwise byte-for-byte what a real
# `helm install` of the same chart+values would produce, since
# `data.helm_template` uses the same template-rendering engine `helm
# template`/`helm install` do; only the out-of-band release bookkeeping is
# missing. See ../../scene/README.md's "Divergence from stack.sh" for the
# full accounting.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
}

locals {
  release_name           = coalesce(var.release_name, "boutique-${var.namespace}")
  living_stack_component = "boutique"
  loadgen_name           = "loadgenerator"
  render_dir             = "${path.root}/.rendered/boutique-${var.namespace}"
}

data "helm_template" "onlineboutique" {
  name       = local.release_name
  repository = var.chart_repository
  chart      = var.chart_name
  version    = var.chart_version
  namespace  = var.namespace

  values = concat(
    [file(var.values_path)],
    var.cart_database_endpoint == null ? [] : [yamlencode({
      cartDatabase = { connectionString = var.cart_database_endpoint }
    })]
  )
}

resource "local_file" "rendered_manifest" {
  filename = "${local.render_dir}/rendered.yaml"
  content  = data.helm_template.onlineboutique.manifest
}

resource "local_file" "kustomization" {
  filename = "${local.render_dir}/kustomization.yaml"
  content = templatefile("${path.module}/templates/kustomization.yaml.tftpl", {
    living_stack           = var.system
    living_stack_component = local.living_stack_component
    loadgen_name           = local.loadgen_name
    loadgen_users          = var.loadgen_users
    loadgen_rate           = var.loadgen_rate
  })
}

resource "null_resource" "apply" {
  depends_on = [local_file.rendered_manifest, local_file.kustomization]

  triggers = {
    namespace          = var.namespace
    render_dir         = local.render_dir
    manifest_hash      = local_file.rendered_manifest.content_md5
    kustomization_hash = local_file.kustomization.content_md5
    kubeconfig         = var.kubeconfig
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # kubectl's own built-in kustomize support (`apply -k`), not a separate
    # `kustomize build | kubectl apply -f -` pipeline: one fewer external
    # binary this module depends on. Rollout waits are a near-verbatim port
    # of ../../stack.sh's own up_gke(): frontend and loadgenerator must come
    # up (hard failure otherwise, matching stack.sh's unguarded `kubectl
    # rollout status` calls for those two), the remaining deployments are
    # best-effort (a warning, not a failure, matching stack.sh's `|| echo
    # ... warning` fallback for everything after those two). Every call
    # carries --kubeconfig explicitly rather than relying on ambient
    # ~/.kube/config or $KUBECONFIG: the ambient current-context is shared
    # across concurrent processes and can move out from under this apply.
    command = <<-EOT
      set -e
      kubectl --kubeconfig ${var.kubeconfig} apply -k ${local.render_dir}
      kubectl --kubeconfig ${var.kubeconfig} rollout status deployment/frontend -n ${var.namespace} --timeout=${var.rollout_timeout_seconds}s
      kubectl --kubeconfig ${var.kubeconfig} rollout status deployment/${local.loadgen_name} -n ${var.namespace} --timeout=${var.rollout_timeout_seconds}s
      for d in $(kubectl --kubeconfig ${var.kubeconfig} get deployments -n ${var.namespace} -o jsonpath='{.items[*].metadata.name}'); do
        kubectl --kubeconfig ${var.kubeconfig} rollout status "deployment/$d" -n ${var.namespace} --timeout=${var.rollout_timeout_seconds}s || \
          echo "onlineboutique: warning: deployment/$d did not become ready in time" >&2
      done
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --kubeconfig ${self.triggers.kubeconfig} delete -k ${self.triggers.render_dir} --ignore-not-found --wait --timeout=300s"
  }
}
