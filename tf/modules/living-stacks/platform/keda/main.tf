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

locals {
  labels = {
    "app.kubernetes.io/name"       = "keda"
    "app.kubernetes.io/managed-by" = "living-stacks"
    "living-stack-component"       = "keda"
    "living-stack"                 = var.system
  }

  crds = [
    "scaledobjects.keda.sh",
    "scaledjobs.keda.sh",
    "triggerauthentications.keda.sh",
    "clustertriggerauthentications.keda.sh"
  ]

  kubeconfig_arg = var.kubeconfig != "" ? "--kubeconfig ${var.kubeconfig}" : ""

  operator_image_repo       = coalesce(var.operator_image_repo, var.operator_image_repository)
  metrics_server_image_repo = coalesce(var.metrics_server_image_repo, var.metrics_server_image_repository)
  webhooks_image_repo       = coalesce(var.webhooks_image_repo, var.webhooks_image_repository)
  teardown_absence_timeout  = coalesce(var.teardown_crs_absence_timeout_seconds, var.teardown_absence_timeout_seconds)

  operator_values = {
    image = {
      keda = {
        registry   = ""
        repository = local.operator_image_repo
        tag        = var.operator_image_tag
      }
      metricsApiServer = {
        registry   = ""
        repository = local.metrics_server_image_repo
        tag        = var.metrics_server_image_tag
      }
      webhooks = {
        registry   = ""
        repository = local.webhooks_image_repo
        tag        = var.webhooks_image_tag
      }
    }
    operator = {
      replicaCount = var.operator_replicas
    }
    metricsServer = {
      replicaCount = var.metrics_server_replicas
    }
    watchNamespace = var.watch_namespace
    webhooks = {
      enabled = var.enable_webhooks
    }
    prometheus = {
      operator = {
        enabled = var.enable_prometheus_metrics
      }
      metricServer = {
        enabled = var.enable_prometheus_metrics
      }
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = var.keda_namespace
    labels = local.labels
  }
}

resource "helm_release" "keda" {
  count = var.install_operator ? 1 : 0

  name       = "keda"
  repository = var.keda_chart_repository
  chart      = "keda"
  version    = var.keda_chart_version
  namespace  = var.keda_namespace

  create_namespace = false

  values = [
    yamlencode(merge(local.operator_values, var.extra_helm_values))
  ]

  wait    = true
  timeout = var.helm_timeout

  depends_on = [kubernetes_namespace_v1.this]
}

resource "null_resource" "wait_for_crds" {
  count      = var.install_crds ? 1 : 0
  depends_on = [helm_release.keda]

  triggers = {
    chart_version = var.keda_chart_version
    kubeconfig    = var.kubeconfig
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      for crd in ${join(" ", local.crds)}; do
        kubectl ${local.kubeconfig_arg} wait --for=condition=Established "crd/$crd" --timeout=${var.crds_ready_timeout}
      done
    EOT
  }
}

resource "null_resource" "crs_absence_poll" {
  count = var.install_operator ? 1 : 0

  depends_on = [helm_release.keda, null_resource.wait_for_crds]

  triggers = {
    kubeconfig    = var.kubeconfig
    namespace_arg = var.watch_namespace != "" ? "-n ${var.watch_namespace}" : "-A"
    deadline      = tostring(local.teardown_absence_timeout)
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      kubeconfig_arg=""
      [ -z "${self.triggers.kubeconfig}" ] || kubeconfig_arg="--kubeconfig ${self.triggers.kubeconfig}"
      deadline=$((SECONDS+${self.triggers.deadline}))
      while true; do
        if query_output="$(kubectl --request-timeout=10s $kubeconfig_arg get scaledobjects.keda.sh,scaledjobs.keda.sh,triggerauthentications.keda.sh,clustertriggerauthentications.keda.sh ${self.triggers.namespace_arg} --no-headers)"; then
          [ -n "$query_output" ] || break
        else
          query_status=$?
          echo "keda: unable to query ScaledObject/TriggerAuthentication CRs (kubectl exit $query_status)" >&2
          exit "$query_status"
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "keda: ScaledObject/TriggerAuthentication CRs still present after ${self.triggers.deadline}s, giving up" >&2
          exit 1
        fi
        sleep 5
      done
    EOT
  }
}
