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

terraform {
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = ">= 0.5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
}

provider "kind" {}

locals {
  # Two run-scoped kind clusters. cluster-1 IS the harness-supplied
  # (run-token-prefixed) cluster_name — the client/primary returned to the harness
  # and addressable in the prompt as {{CLUSTER_NAME}}. cluster-2 appends "-peer"
  # ({{CLUSTER_NAME}}-peer) and hosts the backend. Both are run-unique, so
  # concurrent runs never collide on Docker container/node names.
  c1 = var.cluster_name
  c2 = "${var.cluster_name}-peer"

  # Standalone kubeconfig for cluster-2, written by setup.sh and named by the
  # task's verification_spec (as "{{CLUSTER_NAME}}-peer.kubeconfig"). Verification
  # follows the ambient current-context, so the only portable way to read the
  # second cluster is to hand a leaf verifier its own kubeconfig file. The path is
  # derived from cluster_name, which the harness prefixes per run, so concurrent
  # runs never share it.
  peer_kubeconfig = "/var/tmp/devops-bench/${var.cluster_name}-peer.kubeconfig"
}

# cluster-1 (client/primary). Writes the per-run KUBECONFIG the harness uses.
resource "kind_cluster" "c1" {
  name            = local.c1
  node_image      = var.node_image
  kubeconfig_path = pathexpand(var.kubeconfig_path)
  wait_for_ready  = true
}

# cluster-2 (backend). Writes a SEPARATE kubeconfig so the two resources don't
# clobber the same file during apply; setup.sh merges its context into the per-run
# KUBECONFIG. Both clusters attach to the shared `kind` Docker network by default,
# so their MetalLB-assigned east-west gateway IPs are mutually reachable.
resource "kind_cluster" "c2" {
  name            = local.c2
  node_image      = var.node_image
  kubeconfig_path = pathexpand("${var.kubeconfig_path}-c2")
  wait_for_ready  = true
}

# Outside-the-cluster setup: build the Istio multi-primary federation across both
# clusters and inject the mTLS fault. Runs during `tofu apply`, before the agent.
resource "null_resource" "setup" {
  triggers = {
    c1              = kind_cluster.c1.name
    c2              = kind_cluster.c2.name
    kubeconfig_c2   = pathexpand("${var.kubeconfig_path}-c2")
    peer_kubeconfig = local.peer_kubeconfig
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/setup.sh"
    environment = {
      KUBECONFIG      = pathexpand(var.kubeconfig_path)
      C1              = kind_cluster.c1.name
      C2              = kind_cluster.c2.name
      PEER_KUBECONFIG = local.peer_kubeconfig
      MANIFESTS_DIR   = "${path.module}/manifests"
      ISTIO_VERSION   = var.istio_version
    }
  }

  # Two files outlive the kind resources: the kubeconfig cluster-2 is created
  # into, and the standalone one setup.sh writes for the grader. Both hold live
  # cluster credentials, so remove them on teardown rather than leaving them on
  # the runner.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "rm -f '${self.triggers.kubeconfig_c2}' '${self.triggers.peer_kubeconfig}'"
  }
}
