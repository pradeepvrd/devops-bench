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

# Apache flink-kubernetes-operator (helm, native fit) + the session
# FlinkDeployment CR (no native Terraform resource for flink.apache.org/v1beta1
# in this codebase's provider set, so it goes through null_resource + kubectl,
# same precedent as ../kafka_strimzi and ../../../cdc/tf/modules/cnpg_postgres)
# + a ConfigMap holding the SQL runner jar, mounted directly onto the operator
# pod, that ../flink_sql_job's FlinkSessionJob CRs point at via a file:// jarURI.
#
# That mount replaces an earlier design that served the jar over HTTP from an
# in-cluster Deployment + Service. flink-kubernetes-operator 1.15.0's fix for
# CVE-2026-40564 (SSRF via spec.job.jarURI) permanently rejects an http(s)
# jarURI that resolves to a loopback, link-local, site-local, or any-local
# address, and there is no setting to disable that check; an in-cluster
# Service's ClusterIP always lands in one of those ranges. Mounting the jar as
# a file the operator reads locally sidesteps the check entirely, and it must
# be the operator pod: for a FlinkSessionJob the operator fetches the jar, not
# the session cluster, so mounting it on the session cluster does nothing.
#
# One setting on the operator's own flink-conf.yaml is set explicitly here,
# never left at its default, per factory-303/docs/flink-sessionjob-spike.md
# and the trap this scene's build write-up documents:
#
#   kubernetes.operator.user.artifacts.allowed-schemes defaults to ["https"].
#   The delimiter is a semicolon, not a comma: "https,http,file" parses as ONE
#   scheme whose literal value is the string "https,http,file", and the
#   operator's own error message when it later rejects a file:// jarURI looks
#   identical to the https-only default rejecting it -- there is no signal
#   that the comma was the problem. This must read "https;http;file".

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.0"
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
  # Dedicated per namespace, never shared, mirroring stack.sh's
  # FLINK_OPERATOR_NAMESPACE="flink-operator-${NS}" exactly: a second
  # instance on the same cluster gets its own operator watching only its own
  # namespace, so there is no analogous "skip re-install" flag to expose
  # (unlike ../kafka_strimzi's create_global_resources, which exists because
  # Strimzi's ClusterRoles really are cluster-scoped and shared).
  operator_namespace = "flink-operator-${var.namespace}"

  operator_values = yamlencode({
    defaultConfiguration = {
      # append: true is this chart's own default, so this only adds this key
      # on top of the chart's built-in operator defaults; it does not
      # replace them.
      "flink-conf.yaml" = <<-EOT
        kubernetes.operator.user.artifacts.allowed-schemes: ${var.jar_allowed_schemes}
      EOT
    }
    # Mounts the sql_runner_jar ConfigMap (the copy in the operator's own
    # namespace, below) onto the operator pod at /sql-runner, so a
    # file:///sql-runner/<filename> jarURI resolves there. Keys verified
    # against this chart version's own values.yaml (operatorVolumes /
    # operatorVolumeMounts, each gated by its own "create" flag, both false
    # by default).
    operatorVolumes = {
      create = true
      data = [
        {
          name = "sql-runner-jar"
          configMap = {
            name = kubernetes_config_map_v1.sql_runner_jar_operator.metadata[0].name
          }
        }
      ]
    }
    operatorVolumeMounts = {
      create = true
      data = [
        {
          name      = "sql-runner-jar"
          mountPath = "/sql-runner"
        }
      ]
    }
  })
}

# Created explicitly, rather than via helm_release's own create_namespace,
# because kubernetes_config_map_v1.sql_runner_jar_operator below must exist
# in this namespace before the operator pod's first schedule (its volume
# mount references the ConfigMap by name), and a ConfigMap cannot be created
# in a namespace that does not exist yet. helm_release.flink_operator depends
# on the ConfigMap (transitively, on this namespace too), so a single `tofu
# apply` orders namespace -> ConfigMap -> operator install correctly without
# a second pass.
resource "kubernetes_namespace_v1" "operator" {
  metadata {
    name = local.operator_namespace
    labels = {
      "living-stack"           = var.system
      "living-stack-component" = "streaming"
    }
  }
}

resource "helm_release" "flink_operator" {
  name             = "flink-kubernetes-operator"
  repository       = "https://downloads.apache.org/flink/flink-kubernetes-operator-${var.flink_operator_chart_version}/"
  chart            = "flink-kubernetes-operator"
  version          = var.flink_operator_chart_version
  namespace        = local.operator_namespace
  create_namespace = false

  depends_on = [kubernetes_config_map_v1.sql_runner_jar_operator]

  set {
    name  = "image.repository"
    value = var.flink_operator_image_repo
  }
  set {
    name  = "image.tag"
    value = var.flink_operator_image_tag
  }
  set {
    name  = "watchNamespaces[0]"
    value = var.namespace
  }
  set {
    # Skips cert-manager as a prerequisite, matching stack.sh exactly.
    name  = "webhook.create"
    value = "false"
  }

  values = [local.operator_values]

  wait    = true
  timeout = 300
}

resource "null_resource" "wait_for_crds" {
  depends_on = [helm_release.flink_operator]

  triggers = {
    flink_operator_chart_version = var.flink_operator_chart_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      for crd in flinkdeployments.flink.apache.org flinksessionjobs.flink.apache.org; do
        kubectl --kubeconfig ${var.kubeconfig} wait --for=condition=Established "crd/$crd" --timeout=180s
      done
    EOT
  }
}

# The FlinkDeployment/FlinkSessionJob absence poll spec 3.4 permits to keep,
# the same shape as ../../../cdc/tf/modules/cnpg_postgres's own
# null_resource.pod_absence_poll for CNPG: no native resource tracks the
# operator's own cancellation-with-savepoint teardown timing for these CRs,
# and kubectl_manifest's destroy (both kubectl_manifest.session_cluster below
# and ../flink_sql_job's kubectl_manifest.session_job) returns as soon as the
# API accepts the delete (metadata.deletionTimestamp set), not once the
# object is actually gone -- confirmed live, twice, on real destroys: the
# streaming namespace wedged Terminating forever both times, because
# helm_release.flink_operator was torn down while the operator was still
# mid-cancellation on these CRs, and once the operator that owns their
# finalizers is gone, nothing can ever clear them. The operator must outlive
# every CR it is responsible for finalizing, so this polls for genuine
# absence of both kinds in this module's namespace before letting
# helm_release.flink_operator's own destroy proceed.
#
# Ordering, mirroring cnpg_postgres's pod_absence_poll exactly: this resource
# depends on wait_for_crds, which itself depends on helm_release.flink_operator,
# so on destroy this poll runs BEFORE wait_for_crds and helm_release.flink_operator
# (dependents are destroyed before their dependencies) -- the operator is still
# live while this polls. kubectl_manifest.session_cluster's own depends_on
# below additionally names this resource, so session_cluster (which deletes
# the FlinkDeployment CR) is destroyed BEFORE this poll starts watching for
# both CRs' absence, the same "CR delete already issued, then poll" sequence
# cnpg_postgres uses for its Cluster CR and instance pods. FlinkSessionJob CRs
# are covered too even though they live in ../flink_sql_job's own module
# instances (module.core_job/enrichment_*_job in the scene): those modules'
# own depends_on = [module.kafka, module.flink] already guarantees their
# kubectl_manifest.session_job deletes are issued before anything in this
# module starts destroying, so by the time this poll runs, both CR kinds'
# deletes are in flight and this only has to wait for them to finish.
resource "null_resource" "crs_absence_poll" {
  depends_on = [null_resource.wait_for_crds]

  triggers = {
    namespace  = var.namespace
    kubeconfig = var.kubeconfig
    deadline   = tostring(var.teardown_crs_absence_timeout_seconds)
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    # Requires bash explicitly (not the default /bin/sh) for $SECONDS below.
    command = <<-EOT
      set -e
      deadline=$((SECONDS+${self.triggers.deadline}))
      while true; do
        if query_output="$(kubectl --request-timeout=10s --kubeconfig ${self.triggers.kubeconfig} get flinkdeployments,flinksessionjobs -n ${self.triggers.namespace} --no-headers)"; then
          [ -n "$query_output" ] || break
        else
          query_status=$?
          echo "flink_platform: unable to query FlinkDeployment/FlinkSessionJob CRs in ${self.triggers.namespace} (kubectl exit $query_status)" >&2
          exit "$query_status"
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "flink_platform: FlinkDeployment/FlinkSessionJob CRs in ${self.triggers.namespace} still present after ${self.triggers.deadline}s, giving up" >&2
          exit 1
        fi
        sleep 5
      done
    EOT
  }
}

resource "kubernetes_config_map_v1" "sql_scripts" {
  metadata {
    name      = "flink-sql-scripts"
    namespace = var.namespace
  }

  data = var.sql_scripts
}

resource "kubernetes_config_map_v1" "sql_runner_jar" {
  metadata {
    name      = "flink-sql-runner-jar"
    namespace = var.namespace
  }

  binary_data = {
    (var.jar_filename) = filebase64(var.jar_path)
  }
}

# Same content, in the operator's own namespace: a pod can only mount a
# ConfigMap from its own namespace, and it is the operator pod, not anything
# in var.namespace, that needs the jar mounted -- see main.tf's header
# comment for why.
resource "kubernetes_config_map_v1" "sql_runner_jar_operator" {
  metadata {
    name      = "flink-sql-runner-jar"
    namespace = kubernetes_namespace_v1.operator.metadata[0].name
  }

  binary_data = {
    (var.jar_filename) = filebase64(var.jar_path)
  }
}

resource "local_file" "session_cluster" {
  filename = "${path.root}/.rendered/streaming-flink-sessioncluster-${var.namespace}.yaml"
  content = templatefile("${path.module}/templates/flink-sessioncluster.yaml.tftpl", {
    namespace                    = var.namespace
    system                       = var.system
    session_image                = var.session_cluster_image
    flink_version                = var.flink_version
    taskmanager_slots            = var.taskmanager_slots
    checkpoint_interval          = var.checkpoint_interval
    checkpoints_dir              = var.checkpoints_dir
    savepoints_dir               = var.savepoints_dir
    managed_memory_fraction      = var.managed_memory_fraction
    tolerable_failed_checkpoints = var.tolerable_failed_checkpoints
    kafka_connector_version      = var.kafka_connector_version
    jobmanager_cpu               = var.jobmanager_cpu
    jobmanager_memory            = var.jobmanager_memory
    taskmanager_cpu              = var.taskmanager_cpu
    taskmanager_memory           = var.taskmanager_memory
    sql_scripts_configmap_name   = kubernetes_config_map_v1.sql_scripts.metadata[0].name
  })
}

resource "kubectl_manifest" "session_cluster" {
  # null_resource.crs_absence_poll named here (not just wait_for_crds) so this
  # resource's own destroy -- the `kubectl delete` on the FlinkDeployment CR --
  # runs BEFORE that poll starts watching for both CRs' absence. See
  # crs_absence_poll's own comment above for the full ordering.
  depends_on = [null_resource.wait_for_crds, local_file.session_cluster, null_resource.crs_absence_poll]

  yaml_body = local_file.session_cluster.content
  force_new = false

  timeouts {
    create = "${var.session_ready_timeout_seconds}s"
    update = "${var.session_ready_timeout_seconds}s"
  }

  # FlinkDeployment has no `conditions` array kubectl wait (or this
  # provider's own `wait_for.condition`) can key off of; jobManagerDeployment
  # Status is the operator's own plain-string readiness field, so this polls
  # that field directly instead, a near-verbatim port of stack.sh's own
  # wait_for_json() against the same jsonpath.
  wait_for {
    field {
      key   = "status.jobManagerDeploymentStatus"
      value = "READY"
    }
  }
}

# The FlinkStateSnapshot sweep spec 3.4 permits to keep. A savepoint upgrade
# (../flink_sql_job's default upgradeMode) or a FlinkSessionJob delete's own
# final savepoint leaves a FlinkStateSnapshot CR behind in this namespace,
# carrying a finalizer only a live operator can clear. This has no create
# provisioner: it exists only to run the sweep on destroy, before the
# operator's own helm_release is torn down. It depends on wait_for_crds, the
# same anchor null_resource.apply_session_cluster used before this CR became
# a kubectl_manifest, so it is destroyed before helm_release.flink_operator
# either way; kubectl_manifest.session_cluster's own destroy (a native
# `kubectl delete` on the FlinkDeployment object, no longer riding inside
# this provisioner) also depends on that same anchor, so both run against a
# still-live operator. Every FlinkSessionJob CR that could have left a
# FlinkStateSnapshot behind is already gone by the time this runs
# (streaming/tf/scene's own module.core_job/enrichment_*_job depends_on =
# [module.kafka, module.flink] ties their destroy order to before this
# module's own resources, and this sweep runs inside that same module).
# Kept as a standalone null_resource, not folded back onto
# kubectl_manifest.session_cluster, because it cleans up FlinkStateSnapshot
# objects the session cluster CR does not own or reference; nothing about
# their lifecycle is naturally the session cluster resource's job, only
# ordering relative to the operator's own teardown is.
resource "null_resource" "sweep_flinkstatesnapshots" {
  depends_on = [null_resource.wait_for_crds]

  triggers = {
    namespace  = var.namespace
    kubeconfig = var.kubeconfig
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --kubeconfig ${self.triggers.kubeconfig} delete flinkstatesnapshots --all -n ${self.triggers.namespace} --ignore-not-found --wait --timeout=180s"
  }
}

resource "kubernetes_pod_disruption_budget_v1" "jobmanager" {
  # Depends on the session cluster's own apply rather than relying on
  # implicit ordering from the selector reference below, so this PDB is
  # never created before there is a JobManager pod for it to select
  # (factory-303/src/factory303/stream_runtime.py's own _jobmanager_pdb is
  # applied only after the session cluster's manifests in that runtime's
  # prepare(), for the same reason).
  depends_on = [kubectl_manifest.session_cluster]

  metadata {
    name      = "streaming-flink-jobmanager"
    namespace = var.namespace
    labels = merge(
      {
        "living-stack"           = var.system
        "living-stack-component" = "streaming"
      },
      var.owner != null ? { "factory303.io/owner" = var.owner } : {}
    )
  }

  spec {
    # No max_unavailable here: stream_runtime.py's health gate treats
    # maxUnavailable as required-absent, not merely unset to zero.
    min_available = 1

    selector {
      # Matches the labels the Flink Kubernetes Operator's own native mode
      # applies to the JobManager pod (app/component/type), not anything
      # this module's own podTemplate sets in templates/flink-sessioncluster.yaml.tftpl.
      match_labels = {
        app       = "streaming-flink"
        component = "jobmanager"
        type      = "flink-native-kubernetes"
      }
    }
  }
}

resource "null_resource" "annotate_flink_service_account" {
  count      = var.flink_gsa_email != null ? 1 : 0
  depends_on = [helm_release.flink_operator]

  triggers = {
    namespace       = var.namespace
    flink_gsa_email = var.flink_gsa_email
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # The flink-kubernetes-operator helm chart creates a per-watched-namespace
    # "flink" ServiceAccount (with the RBAC the JobManager needs in native
    # mode to manage its own TaskManager pods) on its own; this only adds the
    # Workload Identity annotation on top of it, rather than fighting that
    # chart for ownership of the whole object the way overlays/gke's
    # kubectl apply --server-side --force-conflicts does.
    command = "kubectl --kubeconfig ${var.kubeconfig} annotate serviceaccount flink -n ${var.namespace} iam.gke.io/gcp-service-account=${var.flink_gsa_email} --overwrite"
  }
}
