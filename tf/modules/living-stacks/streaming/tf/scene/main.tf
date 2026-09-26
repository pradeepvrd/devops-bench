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

# Composes kafka_strimzi + flink_platform + flink_sql_job (x3) + traffic_engine
# into the shape streaming/stack.sh's `up gke` produces, with one deliberate
# departure: SQL submission goes through FlinkSessionJob CRs (../modules/flink_sql_job),
# not stack.sh's disposable sql-client.sh Job. See README.md "Departures from
# stack.sh" for why, and factory-303/docs/flink-sessionjob-spike.md for the
# spike that proved the CR mechanics work.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
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
  # Mirrors stack.sh's compute_derived_vars(), and the exact placeholder
  # names living-stacks' checked-in SQL files (overlays/gke/sql/*.sql) use --
  # these are rendered with templatefile() below, not envsubst, but the
  # substitution vocabulary is unchanged from stack.sh's.
  topic_dot = var.topic_prefix != "" ? "${var.topic_prefix}." : ""

  sql_values = {
    SYSTEM                        = var.system
    KAFKA_BOOTSTRAP               = module.kafka.kafka_bootstrap
    EVENTS_RAW_TOPIC              = module.kafka.topics.events_raw
    EVENTS_AGG_TOPIC              = module.kafka.topics.events_agg
    ORDERS_ENRICHED_TOPIC         = module.kafka.topics.orders_enriched
    PRODUCT_ACTIVITY_TOPIC        = module.kafka.topics.product_activity
    EVENTS_PRODUCT_ENRICHED_TOPIC = module.kafka.topics.events_product_enriched
    GCS_RAW_PATH                  = var.raw_archive_path
    GCS_ENRICHED_PATH             = var.enriched_archive_path
  }

  # Variable defaults cannot reference path.module, so the real defaults for
  # every source-file path this scene reads live here instead (mirrors
  # ../../cdc/tf/scene's own pattern of inlining `${path.module}/../../foo` at
  # the call site rather than as a variable default).
  jar_path                   = coalesce(var.jar_path, "${path.module}/../../sql-runner/target/flink-sql-runner-1.0.0.jar")
  core_sql_path              = coalesce(var.core_sql_path, "${path.module}/../../overlays/gke/sql/job.sql")
  enrichment_orders_sql_path = coalesce(var.enrichment_orders_sql_path, "${path.module}/../../overlays/gke/sql/enrichment-orders.sql")
  enrichment_events_sql_path = coalesce(var.enrichment_events_sql_path, "${path.module}/../../overlays/gke/sql/enrichment-events.sql")
  profile_json_path          = coalesce(var.profile_json_path, "${path.module}/../../overlays/gke/profile.json")
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
    labels = {
      "living-stack"           = var.system
      "living-stack-component" = "streaming"
    }
  }
}

module "kafka" {
  source = "../modules/kafka_strimzi"

  namespace               = kubernetes_namespace_v1.this.metadata[0].name
  system                  = var.system
  topic_prefix            = var.topic_prefix
  strimzi_chart_version   = var.strimzi_chart_version
  create_global_resources = var.create_global_resources
  nodepool_replicas       = var.kafka_nodepool_replicas
  nodepool_storage_type   = var.kafka_nodepool_storage_type
  nodepool_storage_size   = var.kafka_nodepool_storage_size
  kubeconfig              = var.kubeconfig
  topic_config_overrides  = var.topic_config_overrides
  kafka_cr_overrides      = var.kafka_cr_overrides
}

module "flink" {
  source = "../modules/flink_platform"

  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  system          = var.system
  checkpoints_dir = var.checkpoints_dir
  savepoints_dir  = var.savepoints_dir
  jar_path        = local.jar_path
  flink_gsa_email = var.flink_gsa_email
  owner           = var.owner
  kubeconfig      = var.kubeconfig

  sql_scripts = merge({
    "job.sql"               = templatefile(local.core_sql_path, local.sql_values)
    "enrichment-orders.sql" = templatefile(local.enrichment_orders_sql_path, local.sql_values)
    "enrichment-events.sql" = templatefile(local.enrichment_events_sql_path, local.sql_values)
  }, var.extra_sql_scripts)
}

module "core_job" {
  source = "../modules/flink_sql_job"

  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  job_name        = "core"
  deployment_name = module.flink.deployment_name
  jar_filename    = module.flink.jar_filename
  args            = ["${module.flink.sql_scripts_mount_path}/${var.core_sql_filename}"]
  kubeconfig      = var.kubeconfig

  # module.flink here is not redundant with the deployment_name/jar_filename
  # arguments above: deployment_name is a hardcoded literal ("streaming-flink")
  # and jar_filename is just a plain string passthrough, so neither creates a
  # real graph edge to module.flink's own FlinkDeployment CR
  # (../modules/flink_platform's null_resource.apply_session_cluster).
  # Without this explicit depends_on, confirmed live during this scene's own
  # validation: a `tofu apply` that replaces both the session cluster and a
  # tainted FlinkSessionJob can destroy/recreate them concurrently instead of
  # in the operator's required order, and the operator refuses to delete a
  # FlinkDeployment while any FlinkSessionJob still targets it ("The session
  # jobs [...] should be deleted first"), wedging the FlinkDeployment in
  # DELETING with its finalizer blocked -- required manual
  # `kubectl delete flinksessionjob` cleanup to unstick during validation.
  depends_on = [module.kafka, module.flink]
}

module "enrichment_orders_job" {
  source = "../modules/flink_sql_job"

  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  job_name        = "enrichment-orders"
  deployment_name = module.flink.deployment_name
  jar_filename    = module.flink.jar_filename
  args            = ["${module.flink.sql_scripts_mount_path}/enrichment-orders.sql"]
  kubeconfig      = var.kubeconfig

  # See module.core_job's depends_on comment above for why module.flink must
  # be listed explicitly here.
  depends_on = [module.kafka, module.flink]
}

module "enrichment_events_job" {
  source = "../modules/flink_sql_job"

  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  job_name        = "enrichment-events"
  deployment_name = module.flink.deployment_name
  jar_filename    = module.flink.jar_filename
  args            = ["${module.flink.sql_scripts_mount_path}/enrichment-events.sql"]
  kubeconfig      = var.kubeconfig

  # See module.core_job's depends_on comment above for why module.flink must
  # be listed explicitly here.
  depends_on = [module.kafka, module.flink]
}

module "traffic_engine" {
  source = "../modules/traffic_engine"

  namespace            = kubernetes_namespace_v1.this.metadata[0].name
  script_path          = "${path.module}/../../base/producer.py"
  profile_json         = coalesce(var.profile_json_override, file(local.profile_json_path))
  profile_name         = basename(local.profile_json_path)
  kafka_bootstrap      = module.kafka.kafka_bootstrap
  topic                = module.kafka.topics.events_raw
  image                = var.traffic_engine_image
  profile_as_configmap = var.traffic_profile_as_configmap

  # Only starts producing once the SQL jobs it feeds are RUNNING, matching
  # factory303/stream_runtime.py's own scale-to-0-then-1 sequencing
  # (prepare() applies the submit Jobs, waits for them, then scales
  # traffic-engine from 0 to 1) rather than stack.sh's own order (traffic
  # starts before SQL is submitted, which is fine for it since it produces
  # to a topic the core job only starts consuming from once RUNNING anyway).
  depends_on = [module.core_job, module.enrichment_orders_job, module.enrichment_events_job]
}

module "governance_attestation" {
  count  = var.enable_governance_attestation ? 1 : 0
  source = "../modules/governance_attestation"

  namespace              = kubernetes_namespace_v1.this.metadata[0].name
  topic_retention_policy = var.governance_attestation_topic_retention_policy
  schedule               = var.governance_attestation_schedule

  depends_on = [module.kafka]
}
