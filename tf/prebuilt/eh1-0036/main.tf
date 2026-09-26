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

# Stack template (spec 5.3). Every task starts from this skeleton.
#
# Provider pins are exact. helm and kubernetes stay on 2.x because every
# living-stacks scene pins hashicorp/helm "~> 2.15.0" and was written against
# kubernetes 2.x. kind and null match the bench's own prebuilt pins.
terraform {
  required_version = ">= 1.8.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "= 0.11.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "= 2.4.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 2.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 2.17.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "= 3.3.1"
    }
  }
}

provider "kind" {}

# The kind module is sourced from the bench fork by git at the pinned sha,
# never via the dispatch module tf/modules/cluster, whose GKE branch brings the
# google provider into every init.
module "cluster" {
  # Scoped sandbox admission policies require Kubernetes 1.30+.
  node_image = "kindest/node:v1.30.0@sha256:047357ac0cfea04663786a612ba1eaba9702bef25227a794b52890dd8bcd692e"
  source     = "../../modules/cluster/kind"

  cluster_name        = var.cluster_name
  project_id          = var.project_id
  location            = var.location
  kubeconfig_path     = var.kubeconfig_path
  node_count          = var.node_count
  disable_default_cni = var.disable_default_cni
}

# Providers are configured from the cluster module's outputs, never from a
# kubeconfig file, so they depend on the cluster and are configured after it
# exists during apply. lazy_load lets the kubectl provider plan while host and
# certs are still unknown; kubernetes and helm defer on their own.
provider "kubectl" {
  host                   = module.cluster.endpoint
  cluster_ca_certificate = module.cluster.cluster_ca_certificate
  client_certificate     = module.cluster.client_certificate
  client_key             = module.cluster.client_key
  load_config_file       = false
  lazy_load              = true
  apply_retry_count      = 5
}

provider "kubernetes" {
  host                   = module.cluster.endpoint
  cluster_ca_certificate = module.cluster.cluster_ca_certificate
  client_certificate     = module.cluster.client_certificate
  client_key             = module.cluster.client_key
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.endpoint
    cluster_ca_certificate = module.cluster.cluster_ca_certificate
    client_certificate     = module.cluster.client_certificate
    client_key             = module.cluster.client_key
  }
}

# Arms. seed/, repair/, violator/ are modules with two outputs each. They are
# composed by precedence, not sequence: the same object exists once per arm
# with the content that arm calls for. merge() is shallow at the objects key,
# so a repair or violator entry must be the complete object, not a patch.

# Arms. The seed deploys the target with the shortened retention, files the change
# record, and performs the record's own rollback in an apply-time Job. The oracle
# and the violator are each one apply-time Job that starts after that rollback --
# the reference repair, and a redeploy of the wrong job -- so both are proven from
# the state the solver is handed, not from a world that was never broken.
module "seed" {
  source              = "./seed"
  streaming_namespace = var.streaming_namespace
}

locals {
  # The scene override map this render passes, published through outputs.tf so
  # the static gate can hold its keys to the scene registry.
  overrides = {
    # calm with update_customer and delete_stale_order removed. The settlement view
    # compares each order's streamed tier with the ledger's current tier, which is
    # sound only if a customer's tier cannot change under an order already streamed
    # (update_customer re-tiers exactly the hot customers, by the same zipf that
    # picks who orders) and an order cannot vanish from the ledger while it is still
    # in the streamed window (delete_stale_order). Keys are removed, not zeroed:
    # pick_weighted() falls back to the last key on a rounding miss.
    oltp_writer_profile_override = jsonencode({
      base_ops_per_sec   = 2
      day_length_minutes = 120
      diurnal_amplitude  = 0.4
      op_mix = {
        insert_order        = 0.35
        update_order_status = 0.35
        update_stock        = 0.15
        new_customer        = 0.1
      }
      hot_customer_zipf_alpha = 1.1
      batch_burst = {
        prob_per_minute = 0.02
        size            = 15
      }
    })
  }

  arm_objects = {
    oracle   = {}
    violator = {}
  }
  # Arm objects only. The seed's objects apply first, in their own resource, so the
  # oracle and violator Jobs start after the maintenance Job has completed without
  # having to watch it in the cluster (it deletes itself once finished).
  objects = merge(
    {},
    [for arm, o in local.arm_objects : o if arm == var.arm]...
  )

  # The solver operates the stream jobs. The database is not theirs to edit, and
  # the settlement-status exporter's namespace is instrumentation.
  edit_namespaces = [var.streaming_namespace]
}

module "image_preload" {
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images = [
    var.postgres_image,
    var.kafka_image,
    "quay.io/debezium/server:3.6.1.Final",
    "devops-bench/oltp-writer:1.0.0",
    "docker.io/library/flink:1.20",
    "devops-bench/traffic-engine:1.0.0",
    "busybox:1.36",
    "bitnamilegacy/kubectl:1.29",
  ]
  depends_on = [module.cluster]
}

module "scene_streaming" {
  source = "../../modules/living-stacks/streaming/tf/scene"

  kubeconfig                  = var.kubeconfig_path
  namespace                   = var.streaming_namespace
  kafka_nodepool_replicas     = 1
  kafka_nodepool_storage_type = "ephemeral"

  depends_on = [module.image_preload]
}

# CDC feeds the enrichment jobs, delivering into the bus the streaming scene
# creates rather than the scene default, which names a bus nothing deploys.
module "scene_cdc" {
  source = "../../modules/living-stacks/cdc/tf/scene"

  kubeconfig      = var.kubeconfig_path
  namespace       = var.scene_namespace
  kafka_bootstrap = "kafka-kafka-bootstrap.${var.streaming_namespace}.svc:9092"
  profile         = "calm"

  oltp_writer_profile_override = local.overrides.oltp_writer_profile_override

  depends_on = [module.scene_streaming]
}

# The change record, in every arm. See seed/main.tf for why it is not an arm object.
resource "kubernetes_config_map_v1" "change_record" {
  metadata {
    name      = "maintenance-change-record"
    namespace = var.streaming_namespace
  }
  data = {
    "CHG-2291.txt" = module.seed.change_record
  }
  depends_on = [module.scene_streaming]
}

# The seed: the maintenance Job and its RBAC, applied before anything arm-specific.
# The Job is waited on to completion, so the change and its rollback have landed
# before the arm Jobs start and before the control's clock starts.
# Split so the ServiceAccount, Role and RoleBinding exist before the Job starts
# (PR #168 review): in one for_each the Job could race its own permissions.
resource "kubectl_manifest" "seed_rbac" {
  for_each = { for k, v in module.seed.objects : k => v if try(v.kind, "") != "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false


  timeouts {
    create = "1800s"
    update = "1800s"
  }

  depends_on = [
    module.scene_cdc,
    kubectl_manifest.exporter,
    kubectl_manifest.identity_baseline,
  ]
}

resource "kubectl_manifest" "seed" {
  for_each = { for k, v in module.seed.objects : k => v if try(v.kind, "") == "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  dynamic "wait_for" {
    for_each = try(each.value.kind, "") == "Job" ? [1] : []
    content {
      condition {
        type   = "Complete"
        status = "True"
      }
    }
  }

  timeouts {
    create = "1800s"
    update = "1800s"
  }

  depends_on = [kubectl_manifest.seed_rbac,
    module.scene_cdc,
    kubectl_manifest.exporter,
    kubectl_manifest.identity_baseline,
  ]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  # The arm Jobs are waited on to completion, so each arm's action has fully landed
  # before the control's clock starts (the idle agent's turn is only 60s).
  dynamic "wait_for" {
    for_each = contains(["Job"], try(each.value.kind, "")) ? [1] : []
    content {
      condition {
        type   = "Complete"
        status = "True"
      }
    }
  }

  timeouts {
    create = "1800s"
    update = "1800s"
  }

  # The oracle's Job reads the settlement view, and the violator's change must land
  # after the neighbour's identity baseline is stamped.
  depends_on = [
    module.scene_cdc,
    kubectl_manifest.exporter,
    kubectl_manifest.identity_baseline,
    kubectl_manifest.seed,
    kubectl_manifest.seed_settle,
  ]
}

# Baseline identity for the neighbour: the annotations identity_preserved compares
# the live uid and creation time against, as #166 stamps them for every task.
#
# #166 reads them with data.kubernetes_resource, which works for built-in kinds. On
# this FlinkSessionJob CRD the provider decoded the object without metadata (the
# first base control failed at apply: "object with 2 attributes ... no attribute
# named metadata"), so the stamp is taken in the cluster instead, by a Job in the
# instrumentation namespace whose Role can only read and annotate that one kind in
# streaming. Annotating does not bump metadata.generation, so the neighbour stays at
# the generation product-enrichment-job-unchanged expects. Only a
# delete-and-recreate changes uid or creation time; an in-place redeploy of the
# wrong job is caught by its generation instead.
locals {
  identity_stamp = <<-SH
    set -eu
    NS=${var.streaming_namespace}
    uid=$(kubectl -n "$NS" get flinksessionjob enrichment-events -o jsonpath="{.metadata.uid}")
    ts=$(kubectl -n "$NS" get flinksessionjob enrichment-events -o jsonpath="{.metadata.creationTimestamp}")
    [ -n "$uid" ] || exit 1
    [ -n "$ts" ] || exit 1
    kubectl -n "$NS" annotate --overwrite flinksessionjob enrichment-events \
      "devops-bench.io/original-uid=$uid" "devops-bench.io/original-creation-timestamp=$ts"
  SH

  identity_objects = {
    "sa" = {
      apiVersion = "v1", kind = "ServiceAccount"
      metadata   = { name = "identity-baseline", namespace = local.exporter_ns }
    }
    "role" = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "Role"
      metadata   = { name = "identity-baseline", namespace = var.streaming_namespace }
      rules = [{
        apiGroups     = ["flink.apache.org"]
        resources     = ["flinksessionjobs"]
        resourceNames = ["enrichment-events"]
        verbs         = ["get", "patch"]
      }]
    }
    "binding" = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "RoleBinding"
      metadata   = { name = "identity-baseline", namespace = var.streaming_namespace }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "identity-baseline" }
      subjects   = [{ kind = "ServiceAccount", name = "identity-baseline", namespace = local.exporter_ns }]
    }
    "job" = {
      apiVersion = "batch/v1", kind = "Job"
      metadata   = { name = "identity-baseline", namespace = local.exporter_ns }
      spec = {
        backoffLimit = 6
        template = {
          spec = {
            serviceAccountName = "identity-baseline"
            restartPolicy      = "Never"
            containers = [{
              name    = "stamp"
              image   = "bitnamilegacy/kubectl:1.29"
              command = ["bash", "-c", local.identity_stamp]
            }]
          }
        }
      }
    }
  }
}

# Split so the ServiceAccount, Role and RoleBinding exist before the Job starts
# (PR #168 review): in one for_each the Job could race its own permissions.
resource "kubectl_manifest" "identity_baseline_rbac" {
  for_each = { for k, v in local.identity_objects : k => v if k != "job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false


  timeouts {
    create = "600s"
  }

  depends_on = [module.scene_streaming, kubernetes_namespace_v1.exporter]
}

resource "kubectl_manifest" "identity_baseline" {
  for_each = { for k, v in local.identity_objects : k => v if k == "job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  dynamic "wait_for" {
    for_each = each.key == "job" ? [1] : []
    content {
      condition {
        type   = "Complete"
        status = "True"
      }
    }
  }

  timeouts {
    create = "600s"
  }

  depends_on = [kubectl_manifest.identity_baseline_rbac, module.scene_streaming, kubernetes_namespace_v1.exporter]
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules = [
    {
      api_groups = ["flink.apache.org"]
      resources  = ["flinksessionjobs"]
      verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    },
    # Read-only on the session cluster itself: "do not restart the Flink session
    # cluster" is enforced by the grant, not only by the prompt (PR #168 review).
    # No valid repair edits the FlinkDeployment; both observed ones changed only a
    # FlinkSessionJob.
    {
      api_groups = ["flink.apache.org"]
      resources  = ["flinkdeployments"]
      verbs      = ["get", "list", "watch"]
    },
  ]

  depends_on = [module.cluster, kubectl_manifest.seed, kubectl_manifest.seed_settle, kubectl_manifest.objects, kubectl_manifest.identity_baseline]
}

# The maintenance Job deletes itself after completing (seed/main.tf), but its TTL
# runs from completion, and the control's clock can start seconds later: measured on
# base control 01M2SYM4VVGRYP5QFBKNXCN8TB, the Job completed at 10:04:03 and the turn
# started at 10:04:08, a full minute before the Job was gone. This settle Job waits
# until the maintenance Job no longer exists, and the apply waits on it, so the
# script cannot be read at t0. It selects the Job by a label rather than by name and
# only waits while such a Job exists: kubectl_manifest.seed has already seen it
# complete, so if it is already gone there is nothing to wait for (an earlier
# version waited for it to appear first, which could spin if the TTL won the race,
# as the PR review pointed out).
locals {
  settle_script = <<-SH
    set -eu
    while [ -n "$(kubectl -n ${var.streaming_namespace} get jobs -l app.kubernetes.io/component=change-window -o name)" ]; do
      sleep 3
    done
  SH

  settle_objects = {
    "sa" = {
      apiVersion = "v1", kind = "ServiceAccount"
      metadata   = { name = "startup-sync", namespace = local.exporter_ns }
    }
    "role" = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "Role"
      metadata   = { name = "startup-sync", namespace = var.streaming_namespace }
      rules = [{
        apiGroups = ["batch"]
        resources = ["jobs"]
        verbs     = ["get", "list"]
      }]
    }
    "binding" = {
      apiVersion = "rbac.authorization.k8s.io/v1", kind = "RoleBinding"
      metadata   = { name = "startup-sync", namespace = var.streaming_namespace }
      roleRef    = { apiGroup = "rbac.authorization.k8s.io", kind = "Role", name = "startup-sync" }
      subjects   = [{ kind = "ServiceAccount", name = "startup-sync", namespace = local.exporter_ns }]
    }
    "job" = {
      apiVersion = "batch/v1", kind = "Job"
      metadata   = { name = "startup-sync", namespace = local.exporter_ns }
      spec = {
        backoffLimit = 6
        template = {
          spec = {
            serviceAccountName = "startup-sync"
            restartPolicy      = "Never"
            containers = [{
              name    = "settle"
              image   = "bitnamilegacy/kubectl:1.29"
              command = ["bash", "-c", local.settle_script]
            }]
          }
        }
      }
    }
  }
}

# Split so the ServiceAccount, Role and RoleBinding exist before the Job starts
# (PR #168 review): in one for_each the Job could race its own permissions.
resource "kubectl_manifest" "seed_settle_rbac" {
  for_each = { for k, v in local.settle_objects : k => v if k != "job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false


  timeouts {
    create = "600s"
  }

  depends_on = [kubectl_manifest.seed, kubernetes_namespace_v1.exporter]
}

resource "kubectl_manifest" "seed_settle" {
  for_each = { for k, v in local.settle_objects : k => v if k == "job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  dynamic "wait_for" {
    for_each = each.key == "job" ? [1] : []
    content {
      condition {
        type   = "Complete"
        status = "True"
      }
    }
  }

  timeouts {
    create = "600s"
  }

  depends_on = [kubectl_manifest.seed_settle_rbac, kubectl_manifest.seed, kubernetes_namespace_v1.exporter]
}
