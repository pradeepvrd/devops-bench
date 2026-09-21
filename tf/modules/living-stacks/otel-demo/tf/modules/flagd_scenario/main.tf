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

# Applies a named flagd scenario (stack.sh's scenario_apply). The
# flagd-config ConfigMap this scenario replaces is created by the chart
# itself under a fixed, non-release-scoped name, so a typed
# kubernetes_config_map_v1 here would collide with the object helm already
# owns (the same class of ownership problem documented for otel-collector's
# RBAC names in values-gke.yaml). This goes through null_resource + kubectl
# instead, a near-verbatim port of stack.sh's scenario_apply(): replace the
# ConfigMap, then restart and wait for flagd's rollout, since flagd only
# reads its flag file at pod startup.

terraform {
  required_providers {
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

resource "local_file" "scenario_json" {
  filename = "${path.root}/.rendered/otel-demo-scenario-${var.namespace}.json"
  content  = var.scenario_json
}

resource "null_resource" "apply_scenario" {
  triggers = {
    namespace     = var.namespace
    scenario_name = var.scenario_name
    manifest_path = local_file.scenario_json.filename
    content_hash  = local_file.scenario_json.content_md5
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      kubectl --kubeconfig ${var.kubeconfig} create configmap flagd-config -n ${var.namespace} \
        --from-file="demo.flagd.json=${local_file.scenario_json.filename}" \
        --dry-run=client -o yaml | kubectl --kubeconfig ${var.kubeconfig} apply -f -
      kubectl --kubeconfig ${var.kubeconfig} annotate configmap flagd-config -n ${var.namespace} \
        "living-stacks.otel-demo/scenario=${var.scenario_name}" --overwrite >/dev/null
      kubectl --kubeconfig ${var.kubeconfig} rollout restart deployment/flagd -n ${var.namespace}
      kubectl --kubeconfig ${var.kubeconfig} rollout status deployment/flagd -n ${var.namespace} --timeout=${var.flagd_rollout_timeout}
    EOT
  }
}
