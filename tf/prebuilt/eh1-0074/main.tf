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

resource "kubernetes_namespace_v1" "istio_system" {
  metadata {
    name = "istio-system"
    labels = {
      "kubernetes.io/metadata.name" = "istio-system"
      "istio-injection"             = "disabled"
    }
  }
  depends_on = [module.cluster]
}

resource "kubernetes_namespace_v1" "gateway_infra" {
  metadata {
    name = "gateway-infra"
    labels = {
      "living-stack"                = "primary"
      "kubernetes.io/metadata.name" = "gateway-infra"
      "istio-injection"             = "disabled"
    }
  }
  depends_on = [module.cluster]
}

resource "kubernetes_namespace_v1" "catalog_verifier" {
  metadata {
    name = "catalog-verifier"
    labels = {
      "kubernetes.io/metadata.name" = "catalog-verifier"
      "istio-injection"             = "disabled"
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
  controller_name            = "istio.io/gateway-controller"
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
      name     = "grpc-catalog"
      protocol = "HTTP"
      port     = 3550
      hostname = null
      allowed_routes_selector = {
        "gateway.networking.k8s.io/route-allowed" = "true"
      }
    }
  ]

  depends_on = [module.cluster, kubernetes_namespace_v1.gateway_infra, module.image_preload]
}

resource "kubernetes_annotations" "shared_gateway_service_type" {
  api_version = "gateway.networking.k8s.io/v1"
  kind        = "Gateway"

  metadata {
    name      = "shared-gateway"
    namespace = kubernetes_namespace_v1.gateway_infra.metadata[0].name
  }

  annotations = {
    "networking.istio.io/service-type" = "ClusterIP"
  }

  field_manager = "istio-gateway-service-type"
  force         = true
  depends_on    = [module.gateway_api]
}

resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = "1.24.2"
  namespace        = kubernetes_namespace_v1.istio_system.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300

  depends_on = [kubernetes_namespace_v1.istio_system, module.gateway_api]
}

resource "helm_release" "istiod" {
  name             = "istiod"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "istiod"
  version          = "1.24.2"
  namespace        = kubernetes_namespace_v1.istio_system.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      global = {
        hub = "gcr.io/istio-release"
        tag = "1.24.2"
        proxy = {
          resources = {
            requests = {
              cpu    = "10m"
              memory = "48Mi"
            }
            limits = {
              cpu    = "300m"
              memory = "256Mi"
            }
          }
        }
      }
      pilot = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
      meshConfig = {
        accessLogFile = "/dev/stdout"
        defaultConfig = {
          holdApplicationUntilProxyStarts = true
        }
      }
      sidecarInjectorWebhook = {
        enableNamespacesByDefault = true
        neverInjectSelector = [
          {
            matchExpressions = [
              {
                key      = "app"
                operator = "NotIn"
                values   = ["frontend", "productcatalogservice", "checkoutservice", "loadgenerator"]
              }
            ]
          }
        ]
      }
    })
  ]

  depends_on = [helm_release.istio_base, kubernetes_annotations.shared_gateway_service_type]
}

resource "kubectl_manifest" "productcatalog_canary_destination_rule" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1alpha3"
    kind       = "DestinationRule"
    metadata = {
      name      = "productcatalog-canary-mesh-policy"
      namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
    }
    spec = {
      host = "productcatalogservice-canary.boutique.svc.cluster.local"
      trafficPolicy = {
        tls = {
          mode = "ISTIO_MUTUAL"
        }
        portLevelSettings = [
          {
            port = {
              number = 3550
            }
            tls = {
              mode = "DISABLE"
            }
          }
        ]
      }
    }
  })
  server_side_apply = true
  depends_on        = [helm_release.istiod]
}

resource "kubectl_manifest" "productcatalog_http_filter" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1alpha3"
    kind       = "EnvoyFilter"
    metadata = {
      name      = "productcatalog-http-health-adapter"
      namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
    }
    spec = {
      workloadSelector = {
        labels = {
          app = "productcatalogservice"
        }
      }
      configPatches = [
        {
          applyTo = "HTTP_FILTER"
          match = {
            context = "SIDECAR_INBOUND"
            listener = {
              portNumber = 3550
              filterChain = {
                filter = {
                  name = "envoy.filters.network.http_connection_manager"
                  subFilter = {
                    name = "envoy.filters.http.router"
                  }
                }
              }
            }
          }
          patch = {
            operation = "INSERT_BEFORE"
            value = {
              name = "envoy.filters.http.lua"
              typed_config = {
                "@type" = "type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua"
                default_source_code = {
                  inline_string = <<-LUA
                    function envoy_on_request(request_handle)
                      local path = request_handle:headers():get(":path") or ""
                      if string.sub(path, 1, 8) == "/product" then
                        request_handle:respond(
                          {[":status"] = "200", ["content-type"] = "application/json"},
                          '{"status":"ok","backend":"productcatalogservice","version":"stable"}\n'
                        )
                      end
                    end
                  LUA
                }
              }
            }
          }
        }
      ]
    }
  })
  server_side_apply = true
  depends_on        = [helm_release.istiod]
}

module "scene_boutique" {
  source     = "../../modules/living-stacks/boutique/tf/scene"
  kubeconfig = var.kubeconfig_path
  namespace  = "boutique"
  system     = "primary"
  profile    = "calm"

  depends_on = [module.cluster, module.image_preload, helm_release.istiod, kubectl_manifest.productcatalog_http_filter]
}

resource "kubernetes_secret_v1" "productcatalog_canary_script" {
  metadata {
    name      = "productcatalogservice-canary-script"
    namespace = "boutique"
  }
  data = {
    "canary_server.py" = <<-PY
      import socketserver
      import struct

      H2_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

      def hpack_literal(name: bytes, value: bytes) -> bytes:
          return b"\x00" + bytes([len(name)]) + name + bytes([len(value)]) + value

      def build_h2_frame(ftype: int, flags: int, stream_id: int, payload: bytes) -> bytes:
          l = len(payload)
          hdr = bytes([(l >> 16) & 0xff, (l >> 8) & 0xff, l & 0xff, ftype, flags]) + struct.pack(">I", stream_id & 0x7fffffff)
          return hdr + payload

      class CanaryDualHandler(socketserver.BaseRequestHandler):
          def handle(self):
              self.request.settimeout(5.0)
              try:
                  data = self.request.recv(65535)
              except Exception:
                  return
              if not data:
                  return
              body = b'{"status":"ok","backend":"productcatalogservice-canary","version":"canary"}\n'
              if data.startswith(H2_PREFACE):
                  buf = data[len(H2_PREFACE):]
                  self.request.sendall(build_h2_frame(0x04, 0x00, 0, b""))
                  hdr_block = (
                      b"\x88"
                      + hpack_literal(b"content-type", b"application/json")
                      + hpack_literal(b"x-canary-trace-id", b"canary-trace-0074")
                      + hpack_literal(b"content-length", str(len(body)).encode("ascii"))
                  )
                  while True:
                      while len(buf) >= 9:
                          flen = (buf[0] << 16) | (buf[1] << 8) | buf[2]
                          ftype = buf[3]
                          fflags = buf[4]
                          sid = struct.unpack(">I", buf[5:9])[0] & 0x7fffffff
                          if len(buf) < 9 + flen:
                              break
                          payload = buf[9:9 + flen]
                          buf = buf[9 + flen:]
                          if ftype == 0x04 and (fflags & 0x01) == 0:
                              self.request.sendall(build_h2_frame(0x04, 0x01, 0, b""))
                          elif ftype == 0x06 and (fflags & 0x01) == 0:
                              self.request.sendall(build_h2_frame(0x06, 0x01, 0, payload))
                          elif ftype == 0x01 and sid > 0 and (fflags & 0x01) != 0:
                              self.request.sendall(
                                  build_h2_frame(0x01, 0x04, sid, hdr_block)
                                  + build_h2_frame(0x00, 0x01, sid, body)
                              )
                          elif ftype == 0x00 and sid > 0 and (fflags & 0x01) != 0:
                              self.request.sendall(
                                  build_h2_frame(0x01, 0x04, sid, hdr_block)
                                  + build_h2_frame(0x00, 0x01, sid, body)
                              )
                      try:
                          more = self.request.recv(65535)
                          if not more:
                              break
                          buf += more
                      except Exception:
                          break
              elif data.startswith((b"GET ", b"POST ", b"HEAD ", b"PUT ", b"DELETE ", b"OPTIONS ")):
                  resp = (
                      b"HTTP/1.1 200 OK\r\n"
                      b"Content-Type: application/json\r\n"
                      b"X-Canary-Trace-Id: canary-trace-0074\r\n"
                      b"Connection: close\r\n"
                      b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n\r\n" + body
                  )
                  self.request.sendall(resp)
              else:
                  return

      class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
          allow_reuse_address = True

      if __name__ == "__main__":
          with ThreadedTCPServer(("0.0.0.0", 3550), CanaryDualHandler) as srv:
              srv.serve_forever()
    PY
  }
  depends_on = [module.scene_boutique]
}

resource "kubectl_manifest" "productcatalog_canary_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "productcatalogservice-canary"
      namespace = "boutique"
      labels = {
        app = "productcatalogservice-canary"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "productcatalogservice-canary"
        }
      }
      template = {
        metadata = {
          labels = {
            app                       = "productcatalogservice-canary"
            "sidecar.istio.io/inject" = "false"
          }
          annotations = {
            "sidecar.istio.io/inject" = "false"
          }
        }
        spec = {
          volumes = [
            {
              name = "script"
              secret = {
                secretName = kubernetes_secret_v1.productcatalog_canary_script.metadata[0].name
              }
            }
          ]
          containers = [
            {
              name    = "server"
              image   = "python:3.11-slim"
              command = ["python3", "-u", "/app/canary_server.py"]
              ports = [
                {
                  name          = "grpc"
                  containerPort = 3550
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
                  cpu    = "20m"
                  memory = "32Mi"
                }
                limits = {
                  cpu    = "100m"
                  memory = "64Mi"
                }
              }
            }
          ]
        }
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = true
  depends_on        = [kubernetes_secret_v1.productcatalog_canary_script, helm_release.istiod, kubectl_manifest.productcatalog_canary_destination_rule]
}

resource "kubectl_manifest" "gateway_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "gateway"
      namespace = kubernetes_namespace_v1.gateway_infra.metadata[0].name
      labels = {
        app = "shared-gateway"
      }
    }
    spec = {
      type = "ClusterIP"
      selector = {
        "gateway.networking.k8s.io/gateway-name" = "shared-gateway"
      }
      ports = [
        {
          name       = "http"
          port       = 80
          targetPort = 80
        },
        {
          name       = "grpc-catalog"
          port       = 3550
          targetPort = 3550
        }
      ]
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [helm_release.istiod, kubernetes_annotations.shared_gateway_service_type]
}

resource "kubectl_manifest" "shared_gateway_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "shared-gateway"
      namespace = kubernetes_namespace_v1.gateway_infra.metadata[0].name
      labels = {
        app = "shared-gateway"
      }
    }
    spec = {
      type = "ClusterIP"
      selector = {
        "gateway.networking.k8s.io/gateway-name" = "shared-gateway"
      }
      ports = [
        {
          name       = "http"
          port       = 80
          targetPort = 80
        },
        {
          name       = "grpc-catalog"
          port       = 3550
          targetPort = 3550
        }
      ]
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [helm_release.istiod, kubernetes_annotations.shared_gateway_service_type]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true

  wait             = true
  wait_for_rollout = false

  depends_on = [
    module.scene_boutique,
    module.gateway_api,
    helm_release.istiod,
    kubectl_manifest.productcatalog_canary_deployment,
    kubectl_manifest.shared_gateway_service,
    kubectl_manifest.gateway_service
  ]
}

resource "kubernetes_cluster_role_v1" "catalog_verifier" {
  metadata {
    name = "catalog-verifier-reader-eh1-0074"
  }
  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources = [
      "gatewayclasses",
      "gateways",
      "httproutes",
      "referencegrants"
    ]
    verbs = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["", "apps"]
    resources  = ["services", "endpoints", "pods", "namespaces", "deployments"]
    verbs      = ["get", "list", "watch"]
  }
  depends_on = [module.cluster]
}

resource "kubernetes_cluster_role_binding_v1" "catalog_verifier" {
  metadata {
    name = "catalog-verifier-binding-eh1-0074"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.catalog_verifier.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace_v1.catalog_verifier.metadata[0].name
  }
  depends_on = [kubernetes_cluster_role_v1.catalog_verifier, kubernetes_namespace_v1.catalog_verifier]
}

resource "kubernetes_secret_v1" "catalog_verifier_script" {
  metadata {
    name      = "catalog-verifier-script"
    namespace = kubernetes_namespace_v1.catalog_verifier.metadata[0].name
  }
  data = {
    "exporter.py" = <<-PY
      import json
      import socket
      import ssl
      import threading
      import time
      import urllib.error
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      K8S_API = "https://kubernetes.default.svc"

      state = {
          "canary_port_reconciled": False,
          "canary_trace_header_preserved": False,
          "canary_traffic_healthy": False,
          "canary_weight": 0,
          "parent_gateway_valid": False,
          "svc_port": 3551,
          "route_canary_port": 3550,
          "removes_trace_header": True,
      }

      def k8s_req(path):
          try:
              with open(TOKEN_FILE) as f:
                  token = f.read().strip()
              ctx = ssl.create_default_context(cafile=CA_FILE)
              req = urllib.request.Request(
                  f"{K8S_API}{path}",
                  headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
              )
              with urllib.request.urlopen(req, context=ctx, timeout=2.5) as resp:
                  return json.loads(resp.read().decode("utf-8"))
          except Exception:
              return None

      def filters_strip_trace_header(filters_list):
          if not filters_list:
              return False
          for f in filters_list:
              if f.get("type") == "ResponseHeaderModifier":
                  rhm = f.get("responseHeaderModifier") or {}
                  rem = [str(x).lower() for x in (rhm.get("remove") or [])]
                  if "x-canary-trace-id" in rem:
                      return True
          return False

      def check_tcp_port(host, port):
          sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
          sock.settimeout(1.5)
          try:
              sock.connect((host, int(port)))
              return True
          except Exception:
              return False
          finally:
              try:
                  sock.close()
              except Exception:
                  pass

      def probe():
          hr = k8s_req("/apis/gateway.networking.k8s.io/v1/namespaces/gateway-infra/httproutes/productcatalog-route")
          svc = k8s_req("/api/v1/namespaces/boutique/services/productcatalogservice-canary")

          svc_port = None
          svc_target_port = 3550
          if svc:
              ports = (svc.get("spec") or {}).get("ports") or []
              if ports:
                  svc_port = ports[0].get("port")
                  svc_target_port = ports[0].get("targetPort", 3550)
          state["svc_port"] = svc_port

          parent_ok = False
          route_canary_port = None
          canary_weight = 0
          strips_hdr = False

          if hr:
              spec = hr.get("spec") or {}
              prefs = spec.get("parentRefs") or []
              if prefs and prefs[0].get("name") == "shared-gateway":
                  parent_ok = True
              rules = spec.get("rules") or []
              if rules:
                  rule0 = rules[0]
                  strips_hdr = filters_strip_trace_header(rule0.get("filters") or [])
                  brefs = rule0.get("backendRefs") or []
                  for b in brefs:
                      if b.get("name") == "productcatalogservice-canary":
                          route_canary_port = b.get("port")
                          canary_weight = int(b.get("weight", 1))
                          if filters_strip_trace_header(b.get("filters") or []):
                              strips_hdr = True

          state["parent_gateway_valid"] = parent_ok
          state["route_canary_port"] = route_canary_port
          state["canary_weight"] = canary_weight
          state["removes_trace_header"] = strips_hdr

          tcp_reachable = False
          if route_canary_port is not None:
              tcp_reachable = check_tcp_port("productcatalogservice-canary.boutique.svc.cluster.local", route_canary_port)

          port_ok = bool(
              parent_ok
              and svc_port is not None
              and route_canary_port is not None
              and int(svc_port) == 3550
              and int(route_canary_port) == 3550
              and int(svc_target_port) == 3550
              and tcp_reachable
          )
          state["canary_port_reconciled"] = port_ok
          state["canary_trace_header_preserved"] = bool(parent_ok and not strips_hdr)

          # Live end-to-end traffic split probe through the real Istio Envoy Gateway
          canary_e2e_ok = False
          if port_ok and not strips_hdr and canary_weight >= 10:
              saw_stable = False
              saw_canary_with_trace = False
              saw_error_or_missing_trace = False
              for i in range(65):
                  try:
                      req = urllib.request.Request("http://shared-gateway.gateway-infra.svc.cluster.local/product/OLJCESPC7Z")
                      with urllib.request.urlopen(req, timeout=2.0) as resp:
                          raw = resp.read().decode("utf-8", errors="replace")
                          data = json.loads(raw)
                          backend = data.get("backend")
                          if resp.status == 200 and backend == "productcatalogservice":
                              saw_stable = True
                          elif resp.status == 200 and backend == "productcatalogservice-canary":
                              trace_id = resp.headers.get("X-Canary-Trace-Id")
                              if trace_id:
                                  saw_canary_with_trace = True
                              else:
                                  saw_error_or_missing_trace = True
                                  break
                          else:
                              saw_error_or_missing_trace = True
                              break
                  except Exception:
                      saw_error_or_missing_trace = True
                      break
                  if saw_stable and saw_canary_with_trace and i >= 14:
                      break
              if saw_stable and saw_canary_with_trace and not saw_error_or_missing_trace:
                  canary_e2e_ok = True

          state["canary_traffic_healthy"] = bool(canary_e2e_ok and port_ok and not strips_hdr and canary_weight >= 10)

      def loop():
          while True:
              try:
                  probe()
              except Exception:
                  pass
              time.sleep(2.0)

      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path in ("/status", "/status/"):
                  payload = json.dumps(state).encode("utf-8")
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(payload)))
                  self.end_headers()
                  self.wfile.write(payload)
              else:
                  self.send_response(404)
                  self.end_headers()

          def log_message(self, format, *args):
              pass

      if __name__ == "__main__":
          deadline = time.time() + 45
          while time.time() < deadline:
              try:
                  s = socket.create_connection(("shared-gateway.gateway-infra.svc.cluster.local", 80), timeout=1.5)
                  s.close()
                  probe()
                  if state["canary_traffic_healthy"] or not state["canary_port_reconciled"]:
                      break
              except Exception:
                  pass
              time.sleep(1.5)
          try:
              probe()
          except Exception:
              pass
          t = threading.Thread(target=loop, daemon=True)
          t.start()
          ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PY
  }
  depends_on = [kubernetes_namespace_v1.catalog_verifier]
}

resource "kubectl_manifest" "catalog_verifier_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "catalog-status"
      namespace = kubernetes_namespace_v1.catalog_verifier.metadata[0].name
      labels = {
        app = "catalog-status"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "catalog-status"
        }
      }
      template = {
        metadata = {
          labels = {
            app                       = "catalog-status"
            "sidecar.istio.io/inject" = "false"
          }
          annotations = {
            "sidecar.istio.io/inject" = "false"
          }
        }
        spec = {
          volumes = [
            {
              name = "script"
              secret = {
                secretName = kubernetes_secret_v1.catalog_verifier_script.metadata[0].name
              }
            }
          ]
          containers = [
            {
              name    = "prober"
              image   = "python:3.11-slim"
              command = ["python3", "-u", "/app/exporter.py"]
              ports = [
                {
                  containerPort = 8080
                }
              ]
              readinessProbe = {
                httpGet = {
                  path = "/status"
                  port = 8080
                }
                initialDelaySeconds = 2
                periodSeconds       = 2
                failureThreshold    = 30
              }
              volumeMounts = [
                {
                  name      = "script"
                  mountPath = "/app"
                  readOnly  = true
                }
              ]
              resources = {
                requests = {
                  cpu    = "20m"
                  memory = "32Mi"
                }
                limits = {
                  cpu    = "100m"
                  memory = "64Mi"
                }
              }
            }
          ]
        }
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = true
  depends_on = [
    kubectl_manifest.objects,
    helm_release.istiod,
    kubernetes_secret_v1.catalog_verifier_script,
    kubernetes_cluster_role_binding_v1.catalog_verifier
  ]
}

resource "kubectl_manifest" "catalog_verifier_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "catalog-status"
      namespace = kubernetes_namespace_v1.catalog_verifier.metadata[0].name
    }
    spec = {
      selector = {
        app = "catalog-status"
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
  depends_on        = [kubernetes_namespace_v1.catalog_verifier]
}

locals {
  identity_baselines = {}
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
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules = [
    {
      api_groups = ["gateway.networking.k8s.io"]
      resources  = ["httproutes", "gateways", "gatewayclasses", "referencegrants"]
      verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    }
  ]

  depends_on = [module.cluster, kubectl_manifest.objects]
}
