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

# One FlinkSessionJob CR per logical SQL job, replacing base/flink-sql-submit-job.yaml
# and overlays/gke/flink-sql-submit-enrichment-job.yaml's disposable sql-client.sh
# Job with the declarative model factory-303/docs/flink-sessionjob-spike.md proved
# live: the operator tracks exactly one Flink job id per CR, so there is no
# cancel-stale-jobs init container here -- there is nothing to accumulate.
#
# No native Terraform resource exists for flink.apache.org/v1beta1
# FlinkSessionJob (same provider gap ../flink_platform and ../kafka_strimzi
# already work around), so this goes through the alekc/kubectl provider's
# kubectl_manifest resource, matching ../flink_platform's session_cluster and
# ../kafka_strimzi's own precedent for the same problem. Unlike those two,
# FlinkSessionJob has no `status.conditions[]` entry this provider's own
# `wait_for.condition` can key off of: `status.jobStatus.state` is a plain
# string field, so readiness below is `wait_for.field` against that field
# instead, the same shape as ../flink_platform's jobManagerDeploymentStatus
# poll and stack.sh's own wait_for_json().
#
# This used to be two null_resources (an identity-keyed one owning the
# destroy-time `kubectl delete`, and a content-hash-keyed one with no destroy
# provisioner) specifically to avoid a delete-then-recreate on every SQL
# edit: a single null_resource keyed on the rendered manifest's content hash
# would have replaced itself on any content change, and Terraform replacement
# runs the destroy-time provisioner before the create-time one, an explicit
# delete of the live CR followed by a fresh apply, never an in-place `kubectl
# apply` diff (factory-303/catalog/tasks/S-009c/infra/README.md documents a
# real incident where that delete-then-recreate only "worked" because the
# operator's own deletion finalizer took a savepoint, not because anything
# asked it to). A single kubectl_manifest with force_new left false
# reproduces the two-resource split's actual guarantee directly: force_new
# only forces replacement on the object's built-in identity
# (apiVersion/kind/metadata.name/metadata.namespace), which var.job_name and
# var.namespace already fix for the lifetime of this resource, so a
# yaml_body diff on a SQL/spec change is always a real `kubectl apply` patch
# the operator reconciles under `upgradeMode: savepoint`, the same
# stop-with-savepoint-and-redeploy path the old apply resource triggered on
# purpose.
#
# Both the spec-diff savepoint above and the deletion-finalizer savepoint on
# destroy leave a FlinkStateSnapshot CR behind in this same namespace, with a
# finalizer only a live operator can clear. Nothing here deletes those;
# ../flink_platform's null_resource.sweep_flinkstatesnapshots destroy
# provisioner sweeps them, since it is the resource guaranteed to run while
# the operator is still up.

terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}

locals {
  manifest = yamlencode({
    apiVersion = "flink.apache.org/v1beta1"
    kind       = "FlinkSessionJob"
    metadata = {
      name      = var.job_name
      namespace = var.namespace
    }
    spec = {
      deploymentName = var.deployment_name
      job = {
        # The operator fetches the jar from a mounted ConfigMap, not an
        # in-cluster HTTP host: flink-kubernetes-operator 1.15.0's fix for
        # CVE-2026-40564 permanently rejects an http(s) jarURI resolving to an
        # in-cluster address, with no setting to disable that check. See
        # ../flink_platform/main.tf's header comment for the full story.
        jarURI      = "file:///sql-runner/${var.jar_filename}"
        entryClass  = var.entry_class
        args        = var.args
        parallelism = var.parallelism
        upgradeMode = var.upgrade_mode
      }
    }
  })
}

resource "local_file" "session_job" {
  filename = "${path.root}/.rendered/streaming-flink-sessionjob-${var.namespace}-${var.job_name}.yaml"
  content  = local.manifest
}

# The FlinkSessionJob CR itself. force_new left false (this provider's
# default) means only the object's built-in identity
# (apiVersion/kind/metadata.name/metadata.namespace, fixed here by
# var.job_name/var.namespace) ever forces a delete-then-recreate; any other
# yaml_body diff (a different SQL file, jarURI, entryClass, parallelism,
# upgrade_mode, ...) is a real `kubectl apply` patch against the same
# already-existing object, which the operator reconciles under
# `upgradeMode: savepoint` (a real stop-with-savepoint and redeploy it
# performs because we asked it to via a spec diff, not a delete-then-recreate
# that only "worked" because of its own deletion finalizer -- see
# factory-303/catalog/tasks/S-009c/infra/README.md "How seed/repair actually
# apply" for the incident this replaces). On destroy, this resource's own
# `kubectl delete` of the CR is what triggers that deletion-finalizer
# savepoint in the first place.
resource "kubectl_manifest" "session_job" {
  depends_on = [local_file.session_job]

  yaml_body = local.manifest
  force_new = false

  timeouts {
    create = "${var.ready_timeout_seconds}s"
    update = "${var.ready_timeout_seconds}s"
  }

  wait_for {
    field {
      key   = "status.jobStatus.state"
      value = "RUNNING"
    }
  }
}
