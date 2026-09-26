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

# Stack definition for eh1-0048 (boutique + platform/gateway_api coupled task NW-2 / Sec 5.2).
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

module "image_preload" {
  source       = "../../modules/living-stacks/platform/image_preload"
  cluster_name = module.cluster.cluster_name
  images = [
    "devops-bench/traffic-engine:1.0.0",
    "busybox:1.36",
    "bitnamilegacy/kubectl:1.29",
    "curlimages/curl:8.7.1",
    "python:3.11-slim",
  ]
  depends_on = [module.cluster]
}

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

  edit_namespaces = ["gateway-infra", "boutique"]
}

module "scene_boutique" {
  source     = "../../modules/living-stacks/boutique/tf/scene"
  kubeconfig = var.kubeconfig_path
  namespace  = "boutique"
  system     = "primary"
  profile    = "calm"

  depends_on = [module.cluster, module.image_preload]
}

resource "kubernetes_namespace_v1" "gateway_infra" {
  metadata {
    name = "gateway-infra"
    labels = {
      "living-stack"                = "primary"
      "kubernetes.io/metadata.name" = "gateway-infra"
    }
  }
  depends_on = [module.cluster]
}

module "gateway_api" {
  source = "../../modules/living-stacks/platform/gateway_api"

  kubeconfig                 = var.kubeconfig_path
  system                     = "primary"
  gateway_namespace          = kubernetes_namespace_v1.gateway_infra.metadata[0].name
  create_namespace           = false
  gateway_name               = "shared-gateway"
  gateway_class_name         = "shared-gateway-class"
  controller_name            = "living-stacks.devops-bench.io/gateway-fixture"
  install_crds               = true
  install_shared_gateway     = true
  install_controller_fixture = false

  listeners = [
    {
      name                    = "http"
      protocol                = "HTTP"
      port                    = 80
      hostname                = null
      allowed_routes_selector = tomap({})
    },
    {
      name                    = "grpc-checkout"
      protocol                = "HTTP"
      port                    = 50051
      hostname                = null
      allowed_routes_selector = {
        "gateway.networking.k8s.io/route-allowed" = "true"
      }
    }
  ]

  depends_on = [kubernetes_namespace_v1.gateway_infra]
}

resource "kubernetes_namespace_v1" "gateway_verifier" {
  metadata {
    name = "gateway-verifier"
    labels = {
      "kubernetes.io/metadata.name" = "gateway-verifier"
    }
  }
  depends_on = [module.cluster]
}

resource "kubernetes_service_account_v1" "gateway_verifier" {
  metadata {
    name      = "gateway-verifier"
    namespace = kubernetes_namespace_v1.gateway_verifier.metadata[0].name
  }
  depends_on = [kubernetes_namespace_v1.gateway_verifier]
}

resource "kubernetes_cluster_role_v1" "gateway_verifier" {
  metadata {
    name = "gateway-verifier-eh1-0048"
  }

  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources = [
      "gatewayclasses",
      "gateways",
      "grpcroutes",
      "grpcroutes/status",
      "httproutes",
      "referencegrants",
    ]
    verbs = ["get", "list", "watch", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces", "services", "endpoints", "pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "gateway_verifier" {
  metadata {
    name = "gateway-verifier-eh1-0048"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.gateway_verifier.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.gateway_verifier.metadata[0].name
    namespace = kubernetes_namespace_v1.gateway_verifier.metadata[0].name
  }
}

resource "kubernetes_secret_v1" "gateway_verifier_script" {
  metadata {
    name      = "gateway-verifier-script"
    namespace = kubernetes_namespace_v1.gateway_verifier.metadata[0].name
  }
  data = {
    "reconciler.py" = <<-PY
      import json
      import socket
      import ssl
      import sys
      import threading
      import time
      import urllib.error
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      K8S_API = "https://kubernetes.default.svc"

      state = {
          "grpc_checkout_healthy": False,
          "route_accepted": False,
          "refs_resolved": False,
          "target_port_ok": False,
          "h2c_protocol": False,
          "socket_open": False
      }

      def get_k8s_ctx():
          try:
              with open(TOKEN_FILE) as f:
                  token = f.read().strip()
              ctx = ssl.create_default_context(cafile=CA_FILE)
              return token, ctx
          except Exception:
              return None, None

      def k8s_get(url_path, token, ctx):
          req = urllib.request.Request(
              f"{K8S_API}{url_path}",
              headers={"Authorization": f"Bearer {token}", "Accept": "application/json"}
          )
          with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
              return json.loads(resp.read().decode("utf-8"))

      def k8s_patch_status(url_path, patch_dict, token, ctx):
          data = json.dumps(patch_dict).encode("utf-8")
          req = urllib.request.Request(
              f"{K8S_API}{url_path}",
              data=data,
              headers={
                  "Authorization": f"Bearer {token}",
                  "Content-Type": "application/merge-patch+json"
              },
              method="PATCH"
          )
          with urllib.request.urlopen(req, context=ctx, timeout=5) as resp:
              return json.loads(resp.read().decode("utf-8"))

      def reconcile_cycle():
          token, ctx = get_k8s_ctx()
          if not token or not ctx:
              return

          accepted = False
          refs_resolved = False
          target_port_ok = False
          h2c_protocol = False
          socket_open = False

          # 1. Hop 1 evaluation: Gateway listener allowedRoutes selector vs namespace
          try:
              gw = k8s_get("/apis/gateway.networking.k8s.io/v1/namespaces/gateway-infra/gateways/shared-gateway", token, ctx)
              listeners = gw.get("spec", {}).get("listeners", [])
              grpc_listener = None
              for l in listeners:
                  if l.get("name") == "grpc-checkout" or l.get("port") == 50051:
                      grpc_listener = l
                      break

              if grpc_listener:
                  allowed_routes = grpc_listener.get("allowedRoutes", {})
                  namespaces_cfg = allowed_routes.get("namespaces", {})
                  from_mode = namespaces_cfg.get("from", "All")
                  if from_mode in ("All", "Same"):
                      accepted = True
                  elif from_mode == "Selector":
                      selector = namespaces_cfg.get("selector", {})
                      match_labels = selector.get("matchLabels", {})
                      ns = k8s_get("/api/v1/namespaces/gateway-infra", token, ctx)
                      ns_labels = ns.get("metadata", {}).get("labels", {})
                      if match_labels and all(ns_labels.get(k) == v for k, v in match_labels.items()):
                          accepted = True
                      else:
                          accepted = False
          except Exception:
              accepted = False

          # 2. Hop 2 evaluation: ReferenceGrant in boutique permitting GRPCRoute from gateway-infra
          try:
              grants_resp = k8s_get("/apis/gateway.networking.k8s.io/v1beta1/namespaces/boutique/referencegrants", token, ctx)
              items = grants_resp.get("items", [])
              for item in items:
                  spec = item.get("spec", {})
                  from_list = spec.get("from", [])
                  to_list = spec.get("to", [])
                  from_ok = any(
                      f.get("group") == "gateway.networking.k8s.io" and
                      f.get("kind") == "GRPCRoute" and
                      f.get("namespace") == "gateway-infra"
                      for f in from_list
                  )
                  to_ok = any(
                      f.get("group") in ("", "core") and
                      f.get("kind") == "Service" and
                      f.get("name") in (None, "", "checkoutservice")
                      for f in to_list
                  )
                  if from_ok and to_ok:
                      refs_resolved = True
                      break
          except Exception:
              refs_resolved = False

          # 3. Hop 3 & 4 evaluation: Service/checkoutservice port 50051 targetPort and appProtocol
          try:
              svc = k8s_get("/api/v1/namespaces/boutique/services/checkoutservice", token, ctx)
              ports = svc.get("spec", {}).get("ports", [])
              for p in ports:
                  if p.get("port") == 50051:
                      if p.get("targetPort") in (5050, "grpc"):
                          target_port_ok = True
                      if p.get("appProtocol") == "kubernetes.io/h2c":
                          h2c_protocol = True
                      break
          except Exception:
              target_port_ok = False
              h2c_protocol = False

          # 4. Patch GRPCRoute status in gateway-infra
          try:
              route = k8s_get("/apis/gateway.networking.k8s.io/v1/namespaces/gateway-infra/grpcroutes/checkout-route", token, ctx)
              if route:
                  now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                  conditions = [
                      {
                          "type": "Accepted",
                          "status": "True" if accepted else "False",
                          "reason": "Accepted" if accepted else "NotAllowedByListeners",
                          "message": "Route accepted" if accepted else "Route is not allowed by any matching listener",
                          "lastTransitionTime": now_iso
                      },
                      {
                          "type": "ResolvedRefs",
                          "status": "True" if refs_resolved else "False",
                          "reason": "ResolvedRefs" if refs_resolved else "RefNotPermitted",
                          "message": "All references resolved" if refs_resolved else "Backend reference is not permitted",
                          "lastTransitionTime": now_iso
                      }
                  ]
                  if accepted and refs_resolved:
                      if not target_port_ok:
                          conditions.append({
                              "type": "BackendHealthy",
                              "status": "False",
                              "reason": "ConnectionRefused",
                              "message": "Upstream connection refused on backend Service targetPort",
                              "lastTransitionTime": now_iso
                          })
                      elif not h2c_protocol:
                          conditions.append({
                              "type": "BackendHealthy",
                              "status": "False",
                              "reason": "UnsupportedAppProtocol",
                              "message": "GRPCRoute backend Service port must declare standard KEP-1911 cleartext HTTP/2 appProtocol",
                              "lastTransitionTime": now_iso
                          })
                      else:
                          conditions.append({
                              "type": "BackendHealthy",
                              "status": "True",
                              "reason": "Healthy",
                              "message": "Backend gRPC h2c service healthy",
                              "lastTransitionTime": now_iso
                          })
                  status_patch = {
                      "status": {
                          "parents": [
                              {
                                  "parentRef": {
                                      "name": "shared-gateway",
                                      "namespace": "gateway-infra",
                                      "sectionName": "grpc-checkout"
                                  },
                                  "controllerName": "living-stacks.devops-bench.io/gateway-fixture",
                                  "conditions": conditions
                              }
                          ]
                      }
                  }
                  k8s_patch_status("/apis/gateway.networking.k8s.io/v1/namespaces/gateway-infra/grpcroutes/checkout-route/status", status_patch, token, ctx)
          except Exception:
              pass

          # 5. Socket check
          try:
              s = socket.create_connection(("checkoutservice.boutique.svc.cluster.local", 5050), timeout=2)
              s.close()
              socket_open = True
          except Exception:
              socket_open = False

          state["route_accepted"] = accepted
          state["refs_resolved"] = refs_resolved
          state["target_port_ok"] = target_port_ok
          state["h2c_protocol"] = h2c_protocol
          state["socket_open"] = socket_open
          state["grpc_checkout_healthy"] = bool(accepted and refs_resolved and target_port_ok and h2c_protocol and socket_open)

      def worker_loop():
          while True:
              try:
                  reconcile_cycle()
              except Exception:
                  pass
              time.sleep(2)

      class StatusHandler(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path == "/status":
                  body = json.dumps(state).encode("utf-8")
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)
              elif self.path in ("/healthz", "/readyz"):
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.end_headers()
                  self.wfile.write(b'{"status":"healthy"}')
              else:
                  self.send_response(404)
                  self.end_headers()

          def log_message(self, format, *args):
              pass

      if __name__ == "__main__":
          t = threading.Thread(target=worker_loop, daemon=True)
          t.start()
          server = ThreadingHTTPServer(("0.0.0.0", 8080), StatusHandler)
          server.serve_forever()
    PY
  }
  depends_on = [kubernetes_namespace_v1.gateway_verifier, kubernetes_cluster_role_binding_v1.gateway_verifier]
}

resource "kubectl_manifest" "gateway_verifier_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "gateway-verifier"
      namespace = kubernetes_namespace_v1.gateway_verifier.metadata[0].name
      labels = {
        app = "gateway-verifier"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "gateway-verifier"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "gateway-verifier"
          }
        }
        spec = {
          serviceAccountName = kubernetes_service_account_v1.gateway_verifier.metadata[0].name
          volumes = [
            {
              name = "script"
              secret = {
                secretName = kubernetes_secret_v1.gateway_verifier_script.metadata[0].name
              }
            }
          ]
          containers = [
            {
              name    = "verifier"
              image   = "python:3.11-slim"
              command = ["python3", "-u", "/app/reconciler.py"]
              ports = [
                {
                  containerPort = 8080
                }
              ]
              volumeMounts = [
                {
                  name      = "script"
                  mountPath = "/app"
                  readOnly  = true
                }
              ]
              resources = {
                requests = {
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  cpu    = "100m"
                  memory = "128Mi"
                }
              }
            }
          ]
        }
      }
    }
  })
  server_side_apply = true
  wait_for_rollout  = true
  depends_on        = [kubernetes_secret_v1.gateway_verifier_script]
}

resource "kubectl_manifest" "gateway_verifier_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "gateway-status"
      namespace = kubernetes_namespace_v1.gateway_verifier.metadata[0].name
    }
    spec = {
      type = "ClusterIP"
      selector = {
        app = "gateway-verifier"
      }
      ports = [
        {
          name       = "http"
          port       = 8080
          targetPort = 8080
        }
      ]
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.gateway_verifier_deployment]
}

resource "kubectl_manifest" "objects" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") != "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  force_conflicts   = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [module.gateway_api, module.scene_boutique]
}

resource "kubectl_manifest" "objects_jobs" {
  for_each = { for k, v in local.objects : k => v if try(v.kind, "") == "Job" }

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  wait_for {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = "600s"
    update = "600s"
  }

  depends_on = [kubectl_manifest.objects]
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules     = []

  depends_on = [module.cluster, kubectl_manifest.objects]
}

resource "kubernetes_cluster_role_v1" "bench_agent_gateway" {
  metadata {
    name = "bench-agent-gateway-eh1-0048"
  }

  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources  = ["gateways", "httproutes", "grpcroutes", "referencegrants", "gatewayclasses"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = ["gateway-infra"]
    verbs          = ["update", "patch"]
  }

  depends_on = [module.bench_agent]
}

resource "kubernetes_cluster_role_binding_v1" "bench_agent_gateway" {
  metadata {
    name = "bench-agent-gateway-eh1-0048"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.bench_agent_gateway.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "bench-agent"
    namespace = "bench-system"
  }
  depends_on = [module.bench_agent, kubernetes_cluster_role_v1.bench_agent_gateway]
}
