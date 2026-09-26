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
  node_image          = "kindest/node:v1.30.0@sha256:047357ac0cfea04663786a612ba1eaba9702bef25227a794b52890dd8bcd692e"
  source              = "../../modules/cluster/kind"
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

resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = "1.24.2"
  namespace        = kubernetes_namespace_v1.istio_system.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300

  depends_on = [kubernetes_namespace_v1.istio_system]
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
                values   = ["frontend", "cartservice", "checkoutservice", "loadgenerator", "cart-status"]
              }
            ]
          }
        ]
      }
    })
  ]

  depends_on = [helm_release.istio_base]
}

resource "kubectl_manifest" "mesh_strict_mtls" {
  yaml_body = yamlencode({
    apiVersion = "networking.istio.io/v1beta1"
    kind       = "DestinationRule"
    metadata = {
      name      = "mesh-strict-mtls"
      namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
    }
    spec = {
      host = "*.cart-infra.svc.cluster.local"
      trafficPolicy = {
        tls = {
          mode = "ISTIO_MUTUAL"
        }
      }
    }
  })
  server_side_apply = true
  depends_on        = [helm_release.istiod]
}

resource "kubernetes_namespace_v1" "cart_infra" {
  metadata {
    name = "cart-infra"
    labels = {
      "kubernetes.io/metadata.name" = "cart-infra"
      "istio-injection"             = "disabled"
    }
  }
  depends_on = [module.cluster]
}

resource "kubernetes_namespace_v1" "cart_verifier" {
  metadata {
    name = "cart-verifier"
    labels = {
      "kubernetes.io/metadata.name" = "cart-verifier"
      "istio-injection"             = "enabled"
    }
  }
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

  edit_namespaces = ["boutique", "cart-infra"]
}

resource "kubectl_manifest" "redis_cart_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "redis-cart"
      namespace = kubernetes_namespace_v1.cart_infra.metadata[0].name
      labels = {
        app = "redis-cart"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "redis-cart"
        }
      }
      template = {
        metadata = {
          labels = {
            app                       = "redis-cart"
            "sidecar.istio.io/inject" = "false"
          }
          annotations = {
            "sidecar.istio.io/inject" = "false"
          }
        }
        spec = {
          containers = [
            {
              name    = "redis"
              image   = "redis:alpine@sha256:9d317178eceac8454a2284a9e6df2466b93c745529947f0cd42a0fa9609d7005"
              command = ["redis-server", "--port", "6379", "--save", "", "--appendonly", "no"]
              ports = [
                {
                  containerPort = 6379
                }
              ]
              resources = {
                limits = {
                  cpu    = "100m"
                  memory = "128Mi"
                }
                requests = {
                  cpu    = "20m"
                  memory = "32Mi"
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
  depends_on        = [kubernetes_namespace_v1.cart_infra, helm_release.istiod]
}

module "scene_boutique" {
  source            = "../../modules/living-stacks/boutique/tf/scene"
  kubeconfig        = var.kubeconfig_path
  namespace         = "boutique"
  system            = "primary"
  profile           = "calm"
  values_path       = "${path.module}/values.yaml"
  service_endpoints = lookup(local.overrides, "service_endpoints", {})

  depends_on = [module.cluster, helm_release.istiod, kubectl_manifest.mesh_strict_mtls, kubectl_manifest.redis_cart_deployment]
}

resource "kubernetes_cluster_role_v1" "cart_verifier" {
  metadata {
    name = "cart-verifier-reader"
  }
  rule {
    api_groups = ["", "apps", "security.istio.io", "networking.istio.io"]
    resources  = ["services", "deployments", "peerauthentications", "destinationrules", "sidecars"]
    verbs      = ["get", "list", "watch"]
  }
  depends_on = [module.cluster]
}

resource "kubernetes_cluster_role_binding_v1" "cart_verifier" {
  metadata {
    name = "cart-verifier-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.cart_verifier.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace_v1.cart_verifier.metadata[0].name
  }
  depends_on = [kubernetes_namespace_v1.cart_verifier]
}

resource "kubernetes_secret_v1" "cart_verifier_script" {
  metadata {
    name      = "cart-verifier-script"
    namespace = kubernetes_namespace_v1.cart_verifier.metadata[0].name
  }
  data = {
    "exporter.py" = <<-PY
      import json
      import ssl
      import threading
      import time
      import urllib.request
      from http.server import HTTPServer, BaseHTTPRequestHandler

      state = {
          "cart_operations_healthy": False,
          "mtls_strict_enforced": False,
          "destination_rule_configured": False,
          "service_port_protocol_valid": False,
          "cartservice_ready": False
      }

      def get_k8s_json(path):
          try:
              with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
                  token = f.read().strip()
              ctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
              req = urllib.request.Request(
                  f"https://kubernetes.default.svc{path}",
                  headers={"Authorization": f"Bearer {token}"}
              )
              with urllib.request.urlopen(req, context=ctx, timeout=3) as resp:
                  return json.loads(resp.read().decode("utf-8"))
          except Exception:
              return None

      def probe():
          # Check PeerAuthentication in boutique
          pa = get_k8s_json("/apis/security.istio.io/v1beta1/namespaces/boutique/peerauthentications/default")
          pa_strict = False
          if pa:
              mode = (pa.get("spec") or {}).get("mtls", {}).get("mode", "")
              if mode == "STRICT":
                  pa_strict = True
          state["mtls_strict_enforced"] = pa_strict

          # Check DestinationRule in boutique or exported from cart-infra targeting redis-cart
          dr_valid = False
          drs_boutique = get_k8s_json("/apis/networking.istio.io/v1beta1/namespaces/boutique/destinationrules")
          if drs_boutique:
              for item in drs_boutique.get("items") or []:
                  spec = item.get("spec") or {}
                  host = spec.get("host", "")
                  export_to = spec.get("exportTo")
                  visible_in_boutique = (
                      export_to is None
                      or len(export_to) == 0
                      or "." in export_to
                      or "*" in export_to
                      or "boutique" in export_to
                  )
                  tp = spec.get("trafficPolicy") or {}
                  mode = (tp.get("tls") or {}).get("mode", "")
                  port_modes = [(pls.get("tls") or {}).get("mode", "") for pls in (tp.get("portLevelSettings") or [])]
                  if visible_in_boutique and ("redis-cart" in host or "cart-infra" in host) and (mode == "DISABLE" or "DISABLE" in port_modes):
                      dr_valid = True

          drs_infra = get_k8s_json("/apis/networking.istio.io/v1beta1/namespaces/cart-infra/destinationrules")
          if drs_infra:
              for item in drs_infra.get("items") or []:
                  spec = item.get("spec") or {}
                  host = spec.get("host", "")
                  export_to = spec.get("exportTo")
                  exported_to_boutique = (
                      export_to is None
                      or len(export_to) == 0
                      or "*" in export_to
                      or "boutique" in export_to
                  )
                  tp = spec.get("trafficPolicy") or {}
                  mode = (tp.get("tls") or {}).get("mode", "")
                  port_modes = [(pls.get("tls") or {}).get("mode", "") for pls in (tp.get("portLevelSettings") or [])]
                  if exported_to_boutique and ("redis-cart" in host or "cart-infra" in host) and (mode == "DISABLE" or "DISABLE" in port_modes):
                      dr_valid = True
          state["destination_rule_configured"] = dr_valid

          # Check Service/redis-cart in cart-infra port naming
          svc = get_k8s_json("/api/v1/namespaces/cart-infra/services/redis-cart")
          port_valid = False
          if svc:
              ports = (svc.get("spec") or {}).get("ports") or []
              for p in ports:
                  pname = str(p.get("name") or "").lower()
                  aprot = str(p.get("appProtocol") or "").lower()
                  if pname.startswith("tcp") or pname.startswith("redis") or aprot in ("tcp", "redis"):
                      port_valid = True
          state["service_port_protocol_valid"] = port_valid

          # Check Deployment/cartservice in boutique
          cs = get_k8s_json("/apis/apps/v1/namespaces/boutique/deployments/cartservice")
          cs_ready = False
          if cs:
              avail = (cs.get("status") or {}).get("availableReplicas", 0) or 0
              if avail >= 1:
                  cs_ready = True
          state["cartservice_ready"] = cs_ready

          # Always probe storefront /cart through real Envoy mesh sidecars
          live_cart_ok = False
          for _ in range(3):
              try:
                  req = urllib.request.Request("http://frontend.boutique.svc.cluster.local/cart")
                  with urllib.request.urlopen(req, timeout=3.5) as resp:
                      if resp.status == 200:
                          live_cart_ok = True
                          break
              except Exception:
                  live_cart_ok = False
              if not (pa_strict and dr_valid and port_valid):
                  break
              time.sleep(1)

          state["cart_operations_healthy"] = bool(pa_strict and dr_valid and port_valid and cs_ready and live_cart_ok)

      def loop():
          while True:
              try:
                  probe()
              except Exception:
                  pass
              time.sleep(2)

      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path == "/status":
                  body = json.dumps(state).encode("utf-8")
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)
              else:
                  self.send_response(404)
                  self.end_headers()

          def log_message(self, format, *args):
              pass

      if __name__ == "__main__":
          try:
              probe()
          except Exception:
              pass
          t = threading.Thread(target=loop, daemon=True)
          t.start()
          server = HTTPServer(("0.0.0.0", 8080), Handler)
          server.serve_forever()
    PY
  }
  depends_on = [kubernetes_namespace_v1.cart_verifier]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [
    module.scene_boutique,
    helm_release.istiod,
    kubectl_manifest.mesh_strict_mtls,
    kubernetes_namespace_v1.cart_infra
  ]
}

resource "kubectl_manifest" "cart_verifier_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "cart-status"
      namespace = kubernetes_namespace_v1.cart_verifier.metadata[0].name
      labels = {
        app = "cart-status"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "cart-status"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "cart-status"
          }
          annotations = {
            "traffic.sidecar.istio.io/excludeInboundPorts" = "8080"
          }
        }
        spec = {
          volumes = [
            {
              name = "script"
              secret = {
                secretName = kubernetes_secret_v1.cart_verifier_script.metadata[0].name
              }
            }
          ]
          containers = [
            {
              name    = "prober"
              image   = "python:3.13-alpine@sha256:7415fbc3c9e4979cc717d92377ab2bc7b2b4a2af1ac03cc52b5f3f88efedaf3a"
              command = ["python", "-u", "/app/exporter.py"]
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
  wait_for_rollout  = true
  depends_on = [
    kubectl_manifest.objects,
    helm_release.istiod,
    kubernetes_secret_v1.cart_verifier_script,
    kubernetes_cluster_role_binding_v1.cart_verifier
  ]
}

resource "kubectl_manifest" "cart_verifier_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "cart-status"
      namespace = kubernetes_namespace_v1.cart_verifier.metadata[0].name
    }
    spec = {
      selector = {
        app = "cart-status"
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
  depends_on        = [kubernetes_namespace_v1.cart_verifier]
}

locals {
  identity_baselines = {
    "cart-infra/Deployment/redis-cart" = { api_version = "apps/v1" }
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

  depends_on = [kubectl_manifest.redis_cart_deployment]
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
      api_groups = ["networking.istio.io"]
      resources  = ["destinationrules", "virtualservices", "gateways", "serviceentries", "sidecars"]
      verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    },
    {
      api_groups = ["security.istio.io"]
      resources  = ["peerauthentications", "authorizationpolicies", "requestauthentications"]
      verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    }
  ]

  depends_on = [module.cluster, kubectl_manifest.objects]
}
