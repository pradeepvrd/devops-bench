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

resource "kubernetes_namespace_v1" "checkout_verifier" {
  metadata {
    name = "checkout-verifier"
    labels = {
      "kubernetes.io/metadata.name" = "checkout-verifier"
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
      name     = "grpc-checkout"
      protocol = "HTTP"
      port     = 50051
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
                values   = ["frontend", "paymentservice", "checkoutservice", "loadgenerator"]
              }
            ]
          }
        ]
      }
    })
  ]

  depends_on = [helm_release.istio_base, kubernetes_annotations.shared_gateway_service_type]
}

resource "kubectl_manifest" "paymentservice_v1_http_filter" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1alpha3"
    kind       = "EnvoyFilter"
    metadata = {
      name      = "paymentservice-v1-http-adapter"
      namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
    }
    spec = {
      workloadSelector = {
        labels = {
          app = "paymentservice"
        }
      }
      configPatches = [
        {
          applyTo = "HTTP_FILTER"
          match = {
            context = "SIDECAR_INBOUND"
            listener = {
              portNumber = 50051
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
                      if string.sub(path, 1, 9) == "/checkout" then
                        local tier = request_handle:headers():get("x-payment-tier") or ""
                        if tier == "premium" then
                          request_handle:respond(
                            {[":status"] = "404", ["content-type"] = "application/json"},
                            '{"error":"404 Not Found: default paymentservice v1 does not handle premium tier"}\n'
                          )
                        else
                          request_handle:respond(
                            {[":status"] = "200", ["content-type"] = "application/json"},
                            '{"status":"ok","backend":"paymentservice-v1","tier":"standard"}\n'
                          )
                        end
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

resource "kubectl_manifest" "gateway_header_case_filter" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1alpha3"
    kind       = "EnvoyFilter"
    metadata = {
      name      = "istio-gateway-header-matcher"
      namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
    }
    spec = {
      workloadSelector = {
        labels = {
          "gateway.networking.k8s.io/gateway-name" = "shared-gateway"
        }
      }
      configPatches = [
        {
          applyTo = "HTTP_FILTER"
          match = {
            context = "GATEWAY"
            listener = {
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
                  inline_string = "function envoy_on_request(request_handle)\n  local path = request_handle:headers():get(\":path\") or \"\"\n  local tier = request_handle:headers():get(\"x-payment-tier\") or \"\"\n  if string.sub(path, 1, 9) == \"/checkout\" and tier == \"premium\" then\n    request_handle:respond({[\":status\"] = \"404\", [\"content-type\"] = \"application/json\"}, '{\"error\":\"404 Not Found: default paymentservice v1 does not handle premium tier\"}\\n')\n  end\nend\n"
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

  depends_on = [
    module.cluster,
    module.image_preload,
    helm_release.istiod,
    kubectl_manifest.paymentservice_v1_http_filter,
    kubectl_manifest.gateway_header_case_filter
  ]
}

resource "kubernetes_secret_v1" "paymentservice_v2_script" {
  metadata {
    name      = "paymentservice-v2-script"
    namespace = "boutique"
  }
  data = {
    "server.py" = <<-PY
      import socketserver
      import struct
      import sys
      import time

      H2_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
      GOAWAY_FRAME = b"\x00\x00\x08\x07\x00\x00\x00\x00\x00\x00\x00\x00\x01"

      def hpack_literal(name: bytes, value: bytes) -> bytes:
          return b"\x00" + bytes([len(name)]) + name + bytes([len(value)]) + value

      def build_h2_frame(ftype: int, flags: int, stream_id: int, payload: bytes) -> bytes:
          l = len(payload)
          hdr = bytes([(l >> 16) & 0xff, (l >> 8) & 0xff, l & 0xff, ftype, flags]) + struct.pack(">I", stream_id & 0x7fffffff)
          return hdr + payload

      class H2CHandler(socketserver.BaseRequestHandler):
          def handle(self):
              try:
                  self.request.settimeout(4.0)
                  data = self.request.recv(65535)
                  if not data:
                      return
                  body = b'{"status":"ok","backend":"paymentservice-v2","tier":"premium","protocol":"h2c"}\n'
                  if data.startswith(H2_PREFACE):
                      sys.stdout.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ')} INFO [paymentservice-v2] processed premium checkout over HTTP/2 cleartext (h2c)\n")
                      sys.stdout.flush()
                      buf = data[len(H2_PREFACE):]
                      self.request.sendall(build_h2_frame(0x04, 0x00, 0, b""))
                      hdr_block = (
                          b"\x88"
                          + hpack_literal(b"content-type", b"application/json")
                          + hpack_literal(b"x-backend", b"paymentservice-v2")
                          + hpack_literal(b"x-protocol", b"h2c")
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
                          more = self.request.recv(65535)
                          if not more:
                              break
                          buf += more
                  else:
                      first_line = data.splitlines()[0].decode("latin1", errors="replace") if data else ""
                      sys.stderr.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ')} ERROR [paymentservice-v2] transport: http2Server.HandleStreams received bogus greeting {first_line!r} on port 50051\n")
                      sys.stderr.flush()
                      self.request.sendall(GOAWAY_FRAME)
              except Exception:
                  pass

      class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
          allow_reuse_address = True

      if __name__ == "__main__":
          with ThreadedTCPServer(("0.0.0.0", 50051), H2CHandler) as server:
              server.serve_forever()
    PY
  }
  depends_on = [module.scene_boutique]
}

resource "kubectl_manifest" "paymentservice_v2_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "paymentservice-v2"
      namespace = "boutique"
      labels = {
        app = "paymentservice-v2"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "paymentservice-v2"
        }
      }
      template = {
        metadata = {
          labels = {
            app                       = "paymentservice-v2"
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
                secretName = kubernetes_secret_v1.paymentservice_v2_script.metadata[0].name
              }
            }
          ]
          containers = [
            {
              name    = "server"
              image   = "python:3.11-slim"
              command = ["python3", "-u", "/app/server.py"]
              ports = [
                {
                  name          = "grpc"
                  containerPort = 50051
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
  depends_on        = [kubernetes_secret_v1.paymentservice_v2_script, helm_release.istiod]
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
          name       = "grpc-checkout"
          port       = 50051
          targetPort = 50051
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
          name       = "grpc-checkout"
          port       = 50051
          targetPort = 50051
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
    kubectl_manifest.paymentservice_v2_deployment,
    kubectl_manifest.shared_gateway_service,
    kubectl_manifest.gateway_service
  ]
}

resource "kubernetes_cluster_role_v1" "checkout_verifier" {
  metadata {
    name = "checkout-verifier-reconciler-eh1-0063"
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
    api_groups = ["networking.istio.io"]
    resources  = ["envoyfilters"]
    verbs      = ["get", "list", "watch", "patch", "update"]
  }
  rule {
    api_groups = ["", "apps"]
    resources  = ["services", "endpoints", "pods", "namespaces", "deployments"]
    verbs      = ["get", "list", "watch"]
  }
  depends_on = [module.cluster]
}

resource "kubernetes_cluster_role_binding_v1" "checkout_verifier" {
  metadata {
    name = "checkout-verifier-binding-eh1-0063"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.checkout_verifier.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace_v1.checkout_verifier.metadata[0].name
  }
  depends_on = [kubernetes_cluster_role_v1.checkout_verifier, kubernetes_namespace_v1.checkout_verifier]
}

resource "kubernetes_secret_v1" "checkout_verifier_script" {
  metadata {
    name      = "checkout-verifier-script"
    namespace = kubernetes_namespace_v1.checkout_verifier.metadata[0].name
  }
  data = {
    "exporter.py" = <<-PY
      import json
      import re
      import socket
      import ssl
      import threading
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      K8S_API = "https://kubernetes.default.svc"

      state = {
          "header_match_valid": False,
          "h2c_protocol_valid": False,
          "premium_checkout_healthy": False,
          "standard_checkout_healthy": False,
          "parent_gateway_valid": False,
          "last_filter_mode": None,
      }

      def k8s_req(path, method="GET", body=None, content_type="application/json"):
          try:
              with open(TOKEN_FILE) as f:
                  token = f.read().strip()
              ctx = ssl.create_default_context(cafile=CA_FILE)
              data = json.dumps(body).encode("utf-8") if body is not None else None
              headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
              if data is not None:
                  headers["Content-Type"] = content_type
              req = urllib.request.Request(f"{K8S_API}{path}", data=data, headers=headers, method=method)
              with urllib.request.urlopen(req, context=ctx, timeout=2.5) as resp:
                  return json.loads(resp.read().decode("utf-8"))
          except Exception:
              return None

      def header_rule_matches(rule, raw_headers):
          matches = rule.get("matches") or []
          if not matches:
              return True
          for m in matches:
              hdrs = m.get("headers") or []
              if not hdrs:
                  return True
              all_hdrs_ok = True
              for h in hdrs:
                  htype = h.get("type", "Exact")
                  hname = h.get("name", "")
                  hval = h.get("value", "")
                  matched_one = False
                  for rname, rval in raw_headers:
                      if htype == "RegularExpression":
                          try:
                              if (rname == hname or rname.lower() == hname.lower()) and re.search(hval, rval):
                                  matched_one = True
                                  break
                          except Exception:
                              pass
                      else:
                          if rname == hname and rval == hval:
                              matched_one = True
                              break
                  if not matched_one:
                      all_hdrs_ok = False
                      break
              if all_hdrs_ok:
                  return True
          return False

      def sync_gateway_envoy_filter(allow_premium):
          mode = "allow" if allow_premium else "block"
          if state["last_filter_mode"] == mode:
              return
          lua_code = (
              "function envoy_on_request(request_handle)\nend\n"
              if allow_premium
              else (
                  "function envoy_on_request(request_handle)\n"
                  "  local path = request_handle:headers():get(\":path\") or \"\"\n"
                  "  local tier = request_handle:headers():get(\"x-payment-tier\") or \"\"\n"
                  "  if string.sub(path, 1, 9) == \"/checkout\" and tier == \"premium\" then\n"
                  "    request_handle:respond(\n"
                  "      {[\":status\"] = \"404\", [\"content-type\"] = \"application/json\"},\n"
                  "      '{\"error\":\"404 Not Found: default paymentservice v1 does not handle premium tier\"}\\n'\n"
                  "    )\n"
                  "  end\n"
                  "end\n"
              )
          )
          patch_body = {
              "spec": {
                  "workloadSelector": {
                      "labels": {
                          "gateway.networking.k8s.io/gateway-name": "shared-gateway"
                      }
                  },
                  "configPatches": [
                      {
                          "applyTo": "HTTP_FILTER",
                          "match": {
                              "context": "GATEWAY",
                              "listener": {
                                  "filterChain": {
                                      "filter": {
                                          "name": "envoy.filters.network.http_connection_manager",
                                          "subFilter": {
                                              "name": "envoy.filters.http.router"
                                          }
                                      }
                                  }
                              }
                          },
                          "patch": {
                              "operation": "INSERT_BEFORE",
                              "value": {
                                  "name": "envoy.filters.http.lua",
                                  "typed_config": {
                                      "@type": "type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua",
                                      "default_source_code": {
                                          "inline_string": lua_code
                                      }
                                  }
                              }
                          }
                      }
                  ]
              }
          }
          res = k8s_req(
              "/apis/networking.istio.io/v1alpha3/namespaces/istio-system/envoyfilters/istio-gateway-header-matcher",
              method="PATCH",
              body=patch_body,
              content_type="application/merge-patch+json",
          )
          if res is not None:
              state["last_filter_mode"] = mode

      def probe():
          hr = k8s_req("/apis/gateway.networking.k8s.io/v1/namespaces/gateway-infra/httproutes/checkout-route")
          svc = k8s_req("/api/v1/namespaces/boutique/services/paymentservice-v2")

          parent_ok = False
          header_ok = False
          if hr:
              spec = hr.get("spec") or {}
              prefs = spec.get("parentRefs") or []
              if prefs and prefs[0].get("name") == "shared-gateway":
                  parent_ok = True
              rules = spec.get("rules") or []
              for r in rules:
                  brefs = r.get("backendRefs") or []
                  if any(b.get("name") == "paymentservice-v2" and b.get("namespace", "boutique") == "boutique" for b in brefs):
                      if header_rule_matches(r, [("X-Payment-Tier", "premium")]) and not header_rule_matches(r, []):
                          header_ok = True
          state["parent_gateway_valid"] = parent_ok
          state["header_match_valid"] = bool(parent_ok and header_ok)

          sync_gateway_envoy_filter(state["header_match_valid"])

          h2c_ok = False
          if svc:
              ports = (svc.get("spec") or {}).get("ports") or []
              for p in ports:
                  aprot = str(p.get("appProtocol") or "").lower()
                  pname = str(p.get("name") or "").lower()
                  if p.get("port") == 50051 and (
                      aprot in ("kubernetes.io/h2c", "h2c", "grpc", "http2")
                      or pname.startswith("grpc")
                      or pname.startswith("http2")
                      or pname.startswith("h2c")
                  ):
                      h2c_ok = True
          state["h2c_protocol_valid"] = h2c_ok

          prem_ok = False
          std_ok = False
          try:
              req_p = urllib.request.Request(
                  "http://gateway.gateway-infra.svc.cluster.local/checkout",
                  headers={"X-Payment-Tier": "premium"},
              )
              with urllib.request.urlopen(req_p, timeout=2.0) as resp:
                  body_p = json.loads(resp.read().decode("utf-8"))
                  if resp.status == 200 and body_p.get("backend") == "paymentservice-v2" and body_p.get("protocol") == "h2c":
                      prem_ok = True
          except Exception:
              prem_ok = False

          try:
              req_s = urllib.request.Request("http://gateway.gateway-infra.svc.cluster.local/checkout")
              with urllib.request.urlopen(req_s, timeout=2.0) as resp:
                  body_s = json.loads(resp.read().decode("utf-8"))
                  if resp.status == 200 and body_s.get("backend") == "paymentservice-v1":
                      std_ok = True
          except Exception:
              std_ok = False

          state["premium_checkout_healthy"] = bool(prem_ok and std_ok and state["header_match_valid"] and state["h2c_protocol_valid"])
          state["standard_checkout_healthy"] = std_ok

      def loop():
          while True:
              try:
                  probe()
              except Exception:
                  pass
              time.sleep(1.5)

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
                  s = socket.create_connection(("gateway.gateway-infra.svc.cluster.local", 80), timeout=1.5)
                  s.close()
                  probe()
                  if state["premium_checkout_healthy"] or not state["header_match_valid"]:
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
  depends_on = [kubernetes_namespace_v1.checkout_verifier]
}

resource "kubectl_manifest" "checkout_verifier_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "checkout-status"
      namespace = kubernetes_namespace_v1.checkout_verifier.metadata[0].name
      labels = {
        app = "checkout-status"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "checkout-status"
        }
      }
      template = {
        metadata = {
          labels = {
            app                       = "checkout-status"
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
                secretName = kubernetes_secret_v1.checkout_verifier_script.metadata[0].name
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
    kubernetes_secret_v1.checkout_verifier_script,
    kubernetes_cluster_role_binding_v1.checkout_verifier
  ]
}

resource "kubectl_manifest" "checkout_verifier_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "checkout-status"
      namespace = kubernetes_namespace_v1.checkout_verifier.metadata[0].name
    }
    spec = {
      selector = {
        app = "checkout-status"
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
  depends_on        = [kubernetes_namespace_v1.checkout_verifier]
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
