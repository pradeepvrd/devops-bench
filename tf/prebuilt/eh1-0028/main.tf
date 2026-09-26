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
module "seed" {
  source = "./seed"
}

locals {
  # Arm contributions are selected by filtering, not by a conditional.
  #
  # `var.arm == "oracle" ? {} : {}` type-checks only while both
  # branches unify, and an empty object does not unify with an object that has
  # attributes. It survived while the repair arm contributed a single key and
  # failed the moment it contributed two, with "Inconsistent conditional result
  # types" at plan. A comprehension over a map of contributions has one type
  # throughout and cannot develop that fault again.
  arm_overrides = {
    oracle   = {}
    violator = {}
  }
  arm_objects = {
    oracle   = {}
    violator = {}
  }

  overrides = merge(
    module.seed.overrides,
    [for arm, o in local.arm_overrides : o if arm == var.arm]...
  )

  objects = merge(
    module.seed.objects,
    [for arm, o in local.arm_objects : o if arm == var.arm]...
  )

  # Namespaces the solver may edit. The database's own namespace, because the
  # bounded reconstruction is a write against the source table; and the
  # streaming namespace, because clearing the wedged consumer is a change to a
  # FlinkSessionJob that lives there. cdc-verifier is deliberately ABSENT: the
  # ledger the objective is measured from is not the solver's to edit.
  edit_namespaces = [var.scene_namespace, var.streaming_namespace]
}

# The scene's images, loaded into the kind node so no pod pulls at run time. The
# verifier runs one container on the scene's Postgres image and one on the
# Strimzi Kafka image, so both are already covered by the scene entries here.
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
  ]
  depends_on = [module.cluster]
}

# Kafka, Flink and the enrichment jobs. This scene owns the bus; the cdc scene
# below is pointed at it.
#
# One broker with ephemeral storage. Every topic this scene creates is
# replicas = 1 with default.replication.factor = 1 and min.insync.replicas = 1
# (streaming/tf/modules/kafka_strimzi/main.tf), so a single-node pool gives up no
# guarantee the scene actually asks for, and 'ephemeral' is the documented
# kind-lane value in the scene's own variables.tf. Measured: the two scenes
# together apply in about nine minutes and sit at 6 of 31 GiB on one kind node.
module "scene_streaming" {
  source = "../../modules/living-stacks/streaming/tf/scene"

  kubeconfig                  = var.kubeconfig_path
  namespace                   = var.streaming_namespace
  kafka_nodepool_replicas     = 1
  kafka_nodepool_storage_type = "ephemeral"

  depends_on = [module.image_preload]
}

# The cdc scene, delivering into the bus the streaming scene really creates.
#
# The scene's kafka_bootstrap default names a bus in data-platform that nothing
# here deploys; leaving it there would mean no delivery at all, which is
# eh1-0025's condition and not this one. This task is about what happens to
# events that WERE delivered, so the bootstrap is pointed at the real bus and
# the pipeline runs end to end before the seed touches anything.
module "scene_cdc" {
  source = "../../modules/living-stacks/cdc/tf/scene"

  kubeconfig      = var.kubeconfig_path
  namespace       = var.scene_namespace
  kafka_bootstrap = "kafka-kafka-bootstrap.${var.streaming_namespace}.svc:9092"

  # calm, not rush-hour. The traffic only has to be alive enough to keep the
  # pipeline real; a heavier profile buries the incident in noise without making
  # anything harder.
  profile = "calm"

  # calm's op_mix with delete_stale_order removed, so nothing in the traffic ever
  # deletes a row.
  #
  # This is what lets the objective compare the whole table instead of a named
  # set. The comparison has to treat a vanished row as a failure -- otherwise the
  # cheapest fake win is to delete whatever disagrees -- and that is only sound
  # when a row cannot vanish on its own. The recorded batch was already immune,
  # because the seed parks it in a status neither STATUS_FORWARD nor the delete
  # op's selection mentions; this extends the same property to every other row.
  #
  # The key is removed rather than set to 0.0 deliberately. pick_weighted()
  # normalises by the weight sum, but its final fallback is `return keys[-1]`, and
  # delete_stale_order is the last key in the stock calm profile: a float-rounding
  # miss would fire precisely the operation being suppressed.
  oltp_writer_profile_override = jsonencode({
    base_ops_per_sec   = 2
    day_length_minutes = 120
    diurnal_amplitude  = 0.4
    op_mix = {
      insert_order        = 0.35
      update_order_status = 0.35
      update_stock        = 0.15
      new_customer        = 0.1
      update_customer     = 0.05
    }
    hot_customer_zipf_alpha = 1.1
    batch_burst = {
      prob_per_minute = 0.02
      size            = 15
    }
  })

  depends_on = [module.scene_streaming]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true

  # wait is the delete-time wait. wait_for_rollout would block apply on a
  # seeded fault that never rolls out, so it is off for arm objects.
  wait             = true
  wait_for_rollout = false

  # The apply blocks until the maintenance change has run to completion, and on
  # nothing else. This is what makes the seeding cold (design-hazards Hazard 1):
  # the identity is reduced, the batch is emitted, the identity is restored and
  # the consumer is wedged, all before the attempt's clock starts. The first
  # controls run did not wait, so the change was still landing seconds into the
  # observation window and both database-side safeguards reported a violation at
  # t0 against a batch that did not exist yet.
  #
  # The response Job is deliberately NOT waited on: it is the arm's action and
  # belongs inside the observation window, not inside the apply.
  dynamic "wait_for" {
    for_each = (each.key == "maintenance-records/Job/orders-maintenance" || (var.arm == "oracle" && each.key == "maintenance-records/Job/orders-response")) ? [1] : []
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

  # Arm objects read the scene's credentials and act on the running pipeline, so
  # they cannot apply before both scenes exist. The records namespace, the
  # mirrored credential and the seed program are created in oracle.tf and are
  # mounted by the maintenance Job below, so they come first too.
  depends_on = [
    module.scene_cdc,
    kubernetes_namespace_v1.records,
    kubernetes_secret_v1.maintenance_program,
    kubernetes_secret_v1.records_superuser,
  ]
}

# Solver RBAC. Creates bench-system/bench-agent, the ServiceAccount the bench
# sandbox mints its token for. Applied after the scenes and the arm objects so
# the edit namespaces exist.
#
# extra_rules carries the FlinkSessionJob verbs: clearing the wedged consumer is
# the repair, and edit_namespaces alone does not reach a CRD the operator owns.
module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules = [
    {
      api_groups = ["flink.apache.org"]
      resources  = ["flinkdeployments", "flinksessionjobs", "flinkstatesnapshots"]
      verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    },
    {
      api_groups = ["kafka.strimzi.io"]
      resources  = ["kafkas", "kafkatopics", "kafkanodepools", "strimzipodsets"]
      verbs      = ["get", "list", "watch"]
    },
  ]

  depends_on = [module.cluster, kubectl_manifest.objects]
}
