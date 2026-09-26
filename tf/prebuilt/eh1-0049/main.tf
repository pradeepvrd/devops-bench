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

# Stack definition for eh1-0049: streaming + platform/keda coupled task (NW-3 / Sec 5.1).
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

# The kind module is sourced from the bench fork by git at the pinned sha.
module "cluster" {
  node_image = "kindest/node:v1.30.0@sha256:047357ac0cfea04663786a612ba1eaba9702bef25227a794b52890dd8bcd692e"
  source     = "../../modules/cluster/kind"

  cluster_name        = var.cluster_name
  project_id          = var.project_id
  location            = var.location
  kubeconfig_path     = var.kubeconfig_path
  node_count          = var.node_count
  disable_default_cni = var.disable_default_cni
}

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

# Arms. seed/, repair/, violator/ are modules with two outputs each.
module "seed" {
  source = "./seed"
}

locals {
  overrides = merge(
    module.seed.overrides,
    { for k, v in {} : k => v if var.arm == "oracle" },
    { for k, v in {} : k => v if var.arm == "violator" },
  )

  objects = merge(
    module.seed.objects,
    { for k, v in {} : k => v if var.arm == "oracle" },
    { for k, v in {} : k => v if var.arm == "violator" },
  )

  # Solver may edit the streaming namespace where order-indexer and governance policies live.
  edit_namespaces = ["streaming"]
}

module "image_preload" {
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images = [
    "docker.io/library/flink:1.20",
    "registry.k8s.io/kubectl:v1.31.5",
    "devops-bench/traffic-engine:1.0.0",
    "python:3.11-slim",
  ]
  depends_on = [module.cluster]
}

# The pinned streaming scene: Strimzi Kafka, Flink platform, and traffic generator
module "scene_streaming" {
  source                = "../../modules/living-stacks/streaming/tf/scene"
  kubeconfig            = var.kubeconfig_path
  namespace             = "streaming"
  profile_json_override = lookup(local.overrides, "profile_json_override", null)
  depends_on            = [module.cluster, module.image_preload]
}

# The KEDA platform module: operator, metrics server, and autoscaling CRDs
module "keda" {
  source             = "../../modules/living-stacks/platform/keda"
  kubeconfig         = var.kubeconfig_path
  keda_namespace     = "keda"
  create_namespace   = true
  install_operator   = true
  install_crds       = true
  keda_chart_version = "2.16.1"
  depends_on         = [module.cluster, module.image_preload]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [module.scene_streaming, module.keda]
}

# Baseline identity for governance policies and deployment: identity_preserved
# compares live uid and creationTimestamp against these baseline annotations.
locals {
  identity_baselines = {
    "streaming/ResourceQuota/streaming-quota"     = { api_version = "v1" }
    "streaming/LimitRange/streaming-limit-range"   = { api_version = "v1" }
    "streaming/Deployment/order-indexer"          = { api_version = "apps/v1" }
  }
}

data "kubernetes_resource" "identity_baseline" {
  for_each = local.identity_baselines

  api_version = each.value.api_version
  kind        = split("/", each.key)[1]

  metadata {
    name      = split("/", each.key)[2]
    namespace = split("/", each.key)[0] == "_" ? null : split("/", each.key)[0]
  }

  depends_on = [kubectl_manifest.objects]
}

resource "kubernetes_annotations" "identity_baseline" {
  for_each = local.identity_baselines

  api_version = each.value.api_version
  kind        = split("/", each.key)[1]

  metadata {
    name      = split("/", each.key)[2]
    namespace = split("/", each.key)[0] == "_" ? null : split("/", each.key)[0]
  }

  annotations = {
    "devops-bench.io/original-uid"                = data.kubernetes_resource.identity_baseline[each.key].object.metadata.uid
    "devops-bench.io/original-creation-timestamp" = data.kubernetes_resource.identity_baseline[each.key].object.metadata.creationTimestamp
  }

  field_manager = "stagehand-identity-baseline"
  force         = true

  depends_on = [kubectl_manifest.objects]
}

# Solver RBAC: scoped to streaming namespace with permissions for KEDA autoscalers.
module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules = [
    {
      api_groups = ["keda.sh"]
      resources  = ["scaledobjects", "scaledobjects/status", "scaledobjects/scale", "triggerauthentications"]
      verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    }
  ]

  depends_on = [module.cluster, module.scene_streaming, kubectl_manifest.objects]
}

resource "kubernetes_service_account_v1" "keda_lag_sync" {
  metadata {
    name      = "keda-lag-sync"
    namespace = "keda"
  }
  depends_on = [module.keda]
}

resource "kubernetes_cluster_role_v1" "keda_lag_sync" {
  metadata {
    name = "keda-lag-sync-eh1-0049"
  }
  rule {
    api_groups = ["keda.sh"]
    resources  = ["scaledobjects", "scaledobjects/status", "triggerauthentications"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "deployments/scale"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "keda_lag_sync" {
  metadata {
    name = "keda-lag-sync-eh1-0049"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.keda_lag_sync.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.keda_lag_sync.metadata[0].name
    namespace = "keda"
  }
}

resource "kubernetes_secret_v1" "keda_lag_sync_script" {
  metadata {
    name      = "keda-lag-sync-script"
    namespace = "keda"
  }
  data = {
    "sync.py" = <<-PY
      import json
      import ssl
      import time
      import urllib.request

      TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      K8S_API = "https://kubernetes.default.svc"

      def k8s_req(method, path, body=None):
          token = open(TOKEN_FILE).read().strip()
          ctx = ssl.create_default_context(cafile=CA_FILE)
          data = json.dumps(body).encode("utf-8") if body is not None else None
          headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
          if body is not None:
              headers["Content-Type"] = "application/merge-patch+json"
          req = urllib.request.Request(f"{K8S_API}{path}", data=data, headers=headers, method=method)
          with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
              return json.loads(resp.read().decode("utf-8"))

      def reconcile():
          ta = k8s_req("GET", "/apis/keda.sh/v1alpha1/namespaces/streaming/triggerauthentications/order-indexer-auth")
          sec = k8s_req("GET", "/api/v1/namespaces/streaming/secrets/kafka-indexer-credentials")
          so = k8s_req("GET", "/apis/keda.sh/v1alpha1/namespaces/streaming/scaledobjects/order-indexer-scaler")
          sec_data = sec.get("data") or {}
          refs = ta.get("spec", {}).get("secretTargetRef", [])
          auth_ok = False
          for r in refs:
              if r.get("parameter") == "password" and r.get("name") == "kafka-indexer-credentials":
                  if r.get("key") in sec_data:
                      auth_ok = True
                      break
          triggers = so.get("spec", {}).get("triggers", [])
          cg = triggers[0].get("metadata", {}).get("consumerGroup", "") if triggers else ""
          cg_ok = (cg == "order-indexer-cg")
          max_rep = so.get("spec", {}).get("maxReplicaCount", 4)
          now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

          if not auth_ok:
              conditions = [
                  {
                      "type": "Ready",
                      "status": "False",
                      "reason": "ScaledObjectCheckFailed",
                      "message": "Triggers are not active: kafka scaler authentication check failed",
                      "lastTransitionTime": now_iso
                  },
                  {
                      "type": "Active",
                      "status": "False",
                      "reason": "ScalerNotActive",
                      "message": "Scaling is not performed because triggers are not active",
                      "lastTransitionTime": now_iso
                  }
              ]
          elif not cg_ok:
              conditions = [
                  {
                      "type": "Ready",
                      "status": "True",
                      "reason": "ScaledObjectReady",
                      "message": "ScaledObject is defined correctly and is ready for scaling",
                      "lastTransitionTime": now_iso
                  },
                  {
                      "type": "Active",
                      "status": "False",
                      "reason": "ScalerNotActive",
                      "message": "Scaling is not performed because consumer group lag is 0",
                      "lastTransitionTime": now_iso
                  }
              ]
          else:
              conditions = [
                  {
                      "type": "Ready",
                      "status": "True",
                      "reason": "ScaledObjectReady",
                      "message": "ScaledObject is defined correctly and is ready for scaling",
                      "lastTransitionTime": now_iso
                  },
                  {
                      "type": "Active",
                      "status": "True",
                      "reason": "ScalerActive",
                      "message": "Scaling is performed because triggers are active",
                      "lastTransitionTime": now_iso
                  }
              ]
              dep = k8s_req("GET", "/apis/apps/v1/namespaces/streaming/deployments/order-indexer")
              if dep.get("spec", {}).get("replicas", 0) != max_rep:
                  k8s_req("PATCH", "/apis/apps/v1/namespaces/streaming/deployments/order-indexer", {"spec": {"replicas": max_rep}})

          k8s_req(
              "PATCH",
              "/apis/keda.sh/v1alpha1/namespaces/streaming/scaledobjects/order-indexer-scaler/status",
              {"status": {"conditions": conditions}}
          )

      if __name__ == "__main__":
          while True:
              try:
                  reconcile()
              except Exception:
                  pass
              time.sleep(2)
    PY
  }
  depends_on = [module.keda, kubernetes_cluster_role_binding_v1.keda_lag_sync]
}

resource "kubectl_manifest" "keda_lag_sync" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "keda-lag-sync"
      namespace = "keda"
      labels    = { app = "keda-lag-sync" }
    }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "keda-lag-sync" } }
      template = {
        metadata = { labels = { app = "keda-lag-sync" } }
        spec = {
          serviceAccountName = kubernetes_service_account_v1.keda_lag_sync.metadata[0].name
          volumes = [
            {
              name   = "script"
              secret = { secretName = kubernetes_secret_v1.keda_lag_sync_script.metadata[0].name }
            }
          ]
          containers = [
            {
              name         = "sync"
              image        = "python:3.11-slim"
              command      = ["python3", "-u", "/app/sync.py"]
              volumeMounts = [{ name = "script", mountPath = "/app", readOnly = true }]
              resources = {
                requests = { cpu = "25m", memory = "32Mi" }
                limits   = { cpu = "50m", memory = "64Mi" }
              }
            }
          ]
        }
      }
    }
  })
  server_side_apply = true
  wait_for_rollout  = true
  depends_on        = [kubernetes_secret_v1.keda_lag_sync_script, kubectl_manifest.objects]
}
