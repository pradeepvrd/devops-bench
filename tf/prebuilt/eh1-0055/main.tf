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

# Stack definition for eh1-0055 on kind.
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

  edit_namespaces = ["boutique"]
}

module "scene_boutique" {
  source            = "../../modules/living-stacks/boutique/tf/scene"
  kubeconfig        = var.kubeconfig_path
  namespace         = "boutique"
  system            = "primary"
  profile           = "calm"
  values_path       = "${path.module}/values.yaml"
  service_endpoints = lookup(local.overrides, "service_endpoints", {})

  depends_on = [module.cluster]
}

resource "kubernetes_namespace_v1" "currency_verifier" {
  metadata {
    name = "currency-verifier"
    labels = {
      "kubernetes.io/metadata.name" = "currency-verifier"
    }
  }

  depends_on = [module.cluster]
}

resource "kubernetes_cluster_role_binding_v1" "currency_verifier_view" {
  metadata {
    name = "currency-verifier-view"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace_v1.currency_verifier.metadata[0].name
  }
  depends_on = [kubernetes_namespace_v1.currency_verifier]
}

resource "kubernetes_role_v1" "currency_verifier_endpoints" {
  metadata {
    name      = "currency-verifier-endpoints"
    namespace = "boutique"
  }
  rule {
    api_groups = [""]
    resources  = ["endpoints"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  depends_on = [module.scene_boutique]
}

resource "kubernetes_role_binding_v1" "currency_verifier_endpoints" {
  metadata {
    name      = "currency-verifier-endpoints"
    namespace = "boutique"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.currency_verifier_endpoints.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace_v1.currency_verifier.metadata[0].name
  }
  depends_on = [kubernetes_role_v1.currency_verifier_endpoints]
}

resource "kubernetes_secret_v1" "currency_status_script" {
  metadata {
    name      = "currency-status-script"
    namespace = kubernetes_namespace_v1.currency_verifier.metadata[0].name
  }
  data = {
    "verifier.py" = <<-PY
      import json
      import ssl
      import threading
      import time
      import urllib.request
      import urllib.error
      import urllib.parse
      import socket
      from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

      state = {
          "currency_operations_healthy": False,
          "token_audience_valid": False,
          "endpoints_reconciled": False,
          "auth_safeguard_active": False,
          "storefront_accessible": False,
          "last_check_ts": 0,
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
              with urllib.request.urlopen(req, context=ctx, timeout=1.0) as resp:
                  return json.loads(resp.read().decode("utf-8"))
          except Exception:
              return None

      def put_k8s_json(path, data):
          try:
              with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
                  token = f.read().strip()
              ctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
              body = json.dumps(data).encode("utf-8")
              req = urllib.request.Request(
                  f"https://kubernetes.default.svc{path}",
                  data=body,
                  headers={
                      "Authorization": f"Bearer {token}",
                      "Content-Type": "application/json"
                  },
                  method="PUT"
              )
              with urllib.request.urlopen(req, context=ctx, timeout=1.0) as resp:
                  return True
          except Exception:
              return False

      def check_audience(deploy):
          if not deploy:
              return False
          volumes = deploy.get("spec", {}).get("template", {}).get("spec", {}).get("volumes", [])
          for v in volumes:
              if v.get("name") == "mesh-token":
                  sources = v.get("projected", {}).get("sources", [])
                  for s in sources:
                      tok = s.get("serviceAccountToken", {})
                      if tok.get("audience") == "boutique.mesh.internal":
                          return True
          return False

      def run_probes():
          global state
          now = time.time()

          # 1. Check frontend and checkoutservice audience
          fe_deploy = get_k8s_json("/apis/apps/v1/namespaces/boutique/deployments/frontend")
          co_deploy = get_k8s_json("/apis/apps/v1/namespaces/boutique/deployments/checkoutservice")
          fe_aud_ok = check_audience(fe_deploy)
          co_aud_ok = check_audience(co_deploy)
          token_aud_ok = fe_aud_ok and co_aud_ok
          state["token_audience_valid"] = token_aud_ok

          # 2. Check currencyservice deployment env vars
          cs_deploy = get_k8s_json("/apis/apps/v1/namespaces/boutique/deployments/currencyservice")
          auth_active = False
          if cs_deploy:
              containers = cs_deploy.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
              for c in containers:
                  env = c.get("env", [])
                  has_auth = any(e.get("name") == "AUTH_REQUIRE_PROJECTED_TOKEN" and e.get("value") == "true" for e in env)
                  has_aud = any(e.get("name") == "AUTH_EXPECTED_AUDIENCE" and e.get("value") == "boutique.mesh.internal" for e in env)
                  if has_auth and has_aud:
                      auth_active = True
                      break
          state["auth_safeguard_active"] = auth_active

          # 3. Check currencyservice service selector and endpoints
          cs_svc = get_k8s_json("/api/v1/namespaces/boutique/services/currencyservice")
          has_selector = False
          if cs_svc:
              selector = cs_svc.get("spec", {}).get("selector", {})
              if selector and selector.get("app") == "currencyservice":
                  has_selector = True

          # Check endpoints
          cs_ep = get_k8s_json("/api/v1/namespaces/boutique/endpoints/currencyservice")
          stale_ip_present = False
          if cs_ep:
              subsets = cs_ep.get("subsets", [])
              for sub in subsets:
                  for addr in sub.get("addresses", []):
                      ip = addr.get("ip")
                      if ip == "10.244.1.99":
                          stale_ip_present = True

          # If Service does NOT have a selector, maintain the stale IP and live pod IP in Endpoints
          if not has_selector:
              pods = get_k8s_json("/api/v1/namespaces/boutique/pods?labelSelector=app%3Dcurrencyservice")
              live_pod_ip = None
              if pods:
                  for p in pods.get("items", []):
                      if p.get("status", {}).get("phase") == "Running":
                          live_pod_ip = p.get("status", {}).get("podIP")
                          if live_pod_ip:
                              break
              if live_pod_ip and cs_ep:
                  cur_ips = set()
                  for sub in cs_ep.get("subsets", []):
                      for addr in sub.get("addresses", []):
                          cur_ips.add(addr.get("ip"))
                  if "10.244.1.99" not in cur_ips or live_pod_ip not in cur_ips:
                      cs_ep["subsets"] = [
                          {
                              "addresses": [{"ip": live_pod_ip}, {"ip": "10.244.1.99"}],
                              "ports": [{"name": "grpc", "port": 7000}]
                          }
                      ]
                      put_k8s_json("/api/v1/namespaces/boutique/endpoints/currencyservice", cs_ep)
                      stale_ip_present = True

          endpoints_ok = has_selector and (not stale_ip_present)
          state["endpoints_reconciled"] = endpoints_ok

          # 4. Check storefront accessibility
          fe_ok = False
          try:
              with urllib.request.urlopen("http://frontend.boutique.svc.cluster.local/", timeout=1.0) as resp:
                  fe_ok = (resp.status == 200)
          except Exception:
              fe_ok = False
          state["storefront_accessible"] = fe_ok

          # 5. Check currency conversion operations end-to-end
          currency_ok = False
          if token_aud_ok and endpoints_ok and auth_active and fe_ok:
              try:
                  successes = 0
                  for _ in range(5):
                      req_data = urllib.parse.urlencode({"currency_code": "EUR"}).encode("utf-8")
                      req = urllib.request.Request(
                          "http://frontend.boutique.svc.cluster.local/setCurrency",
                          data=req_data,
                          headers={"Content-Type": "application/x-www-form-urlencoded"}
                      )
                      with urllib.request.urlopen(req, timeout=1.0) as resp:
                          if resp.status in (200, 302):
                              successes += 1
                  if successes == 5:
                      currency_ok = True
              except Exception:
                  currency_ok = False

          state["currency_operations_healthy"] = currency_ok
          state["last_check_ts"] = now

      def probe_worker():
          while True:
              try:
                  run_probes()
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
              else:
                  self.send_response(404)
                  self.end_headers()

          def log_message(self, format, *args):
              pass

      if __name__ == "__main__":
          t = threading.Thread(target=probe_worker, daemon=True)
          t.start()
          server = ThreadingHTTPServer(("0.0.0.0", 8080), StatusHandler)
          server.serve_forever()
    PY
  }
  depends_on = [kubernetes_namespace_v1.currency_verifier, kubernetes_cluster_role_binding_v1.currency_verifier_view]
}

resource "kubectl_manifest" "currency_status_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "currency-status"
      namespace = kubernetes_namespace_v1.currency_verifier.metadata[0].name
      labels = {
        app = "currency-status"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "currency-status"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "currency-status"
          }
        }
        spec = {
          volumes = [
            {
              name = "script"
              secret = {
                secretName = kubernetes_secret_v1.currency_status_script.metadata[0].name
              }
            }
          ]
          containers = [
            {
              name    = "verifier"
              image   = "python:3.13-alpine@sha256:7415fbc3c9e4979cc717d92377ab2bc7b2b4a2af1ac03cc52b5f3f88efedaf3a"
              command = ["python", "-u", "/app/verifier.py"]
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
  depends_on        = [kubernetes_secret_v1.currency_status_script]
}

resource "kubectl_manifest" "currency_status_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "currency-status"
      namespace = kubernetes_namespace_v1.currency_verifier.metadata[0].name
    }
    spec = {
      type = "ClusterIP"
      selector = {
        app = "currency-status"
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
  depends_on        = [kubernetes_namespace_v1.currency_verifier]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  force_conflicts   = true

  wait             = true
  wait_for_rollout = false
  depends_on       = [module.scene_boutique]
}

resource "kubectl_manifest" "frontend_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "frontend"
      namespace = "boutique"
      labels = {
        app = "frontend"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "frontend"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "frontend"
          }
        }
        spec = {
          serviceAccountName = "frontend"
          volumes = [
            {
              name = "mesh-token"
              projected = {
                sources = [
                  {
                    serviceAccountToken = {
                      path              = "token"
                      expirationSeconds = 600
                      audience          = "api.legacy.internal"
                    }
                  }
                ]
              }
            }
          ]
          containers = [
            {
              name  = "server"
              image = "us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/frontend:v0.10.6"
              ports = [
                {
                  containerPort = 8080
                }
              ]
              volumeMounts = [
                {
                  name      = "mesh-token"
                  mountPath = "/var/run/secrets/mesh"
                  readOnly  = true
                }
              ]
              readinessProbe = {
                initialDelaySeconds = 10
                httpGet = {
                  path = "/_healthz"
                  port = 8080
                  httpHeaders = [
                    {
                      name  = "Cookie"
                      value = "shop_session-id=x-readiness-probe"
                    }
                  ]
                }
              }
              livenessProbe = {
                initialDelaySeconds = 10
                httpGet = {
                  path = "/_healthz"
                  port = 8080
                  httpHeaders = [
                    {
                      name  = "Cookie"
                      value = "shop_session-id=x-liveness-probe"
                    }
                  ]
                }
              }
              env = [
                { name = "PORT", value = "8080" },
                { name = "PRODUCT_CATALOG_SERVICE_ADDR", value = "productcatalogservice:3550" },
                { name = "CURRENCY_SERVICE_ADDR", value = "currencyservice:7000" },
                { name = "CART_SERVICE_ADDR", value = "cartservice:7070" },
                { name = "RECOMMENDATION_SERVICE_ADDR", value = "recommendationservice:8080" },
                { name = "SHIPPING_SERVICE_ADDR", value = "shippingservice:50051" },
                { name = "CHECKOUT_SERVICE_ADDR", value = "checkoutservice:5050" },
                { name = "AD_SERVICE_ADDR", value = "adservice:9555" },
                { name = "SHOPPING_ASSISTANT_SERVICE_ADDR", value = "shoppingassistantservice:80" },
                { name = "ENV_PLATFORM", value = "local" },
                { name = "CYMBAL_BRANDING", value = "false" },
                { name = "ENABLE_ASSISTANT", value = "false" },
                { name = "ENABLE_SINGLE_SHARED_SESSION", value = "false" }
              ]
              resources = {
                limits = {
                  cpu    = "200m"
                  memory = "128Mi"
                }
                requests = {
                  cpu    = "50m"
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
  depends_on        = [module.scene_boutique, kubectl_manifest.objects]
}

resource "kubectl_manifest" "checkoutservice_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "checkoutservice"
      namespace = "boutique"
      labels = {
        app = "checkoutservice"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "checkoutservice"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "checkoutservice"
          }
        }
        spec = {
          serviceAccountName = "checkoutservice"
          volumes = [
            {
              name = "mesh-token"
              projected = {
                sources = [
                  {
                    serviceAccountToken = {
                      path              = "token"
                      expirationSeconds = 600
                      audience          = "api.legacy.internal"
                    }
                  }
                ]
              }
            }
          ]
          containers = [
            {
              name  = "server"
              image = "us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/checkoutservice:v0.10.6"
              ports = [
                {
                  containerPort = 5050
                }
              ]
              volumeMounts = [
                {
                  name      = "mesh-token"
                  mountPath = "/var/run/secrets/mesh"
                  readOnly  = true
                }
              ]
              readinessProbe = {
                grpc = {
                  port = 5050
                }
              }
              livenessProbe = {
                grpc = {
                  port = 5050
                }
              }
              env = [
                { name = "PORT", value = "5050" },
                { name = "PRODUCT_CATALOG_SERVICE_ADDR", value = "productcatalogservice:3550" },
                { name = "SHIPPING_SERVICE_ADDR", value = "shippingservice:50051" },
                { name = "PAYMENT_SERVICE_ADDR", value = "paymentservice:50051" },
                { name = "EMAIL_SERVICE_ADDR", value = "emailservice:5000" },
                { name = "CURRENCY_SERVICE_ADDR", value = "currencyservice:7000" },
                { name = "CART_SERVICE_ADDR", value = "cartservice:7070" }
              ]
              resources = {
                limits = {
                  cpu    = "200m"
                  memory = "128Mi"
                }
                requests = {
                  cpu    = "50m"
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
  depends_on        = [module.scene_boutique, kubectl_manifest.objects]
}

resource "kubectl_manifest" "currencyservice_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "currencyservice"
      namespace = "boutique"
      labels = {
        app = "currencyservice"
      }
    }
    spec = {
      replicas = 1
      selector = {
        matchLabels = {
          app = "currencyservice"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "currencyservice"
          }
        }
        spec = {
          serviceAccountName            = "currencyservice"
          terminationGracePeriodSeconds = 5
          volumes = [
            {
              name = "auth-interceptor"
              configMap = {
                name = "currencyservice-auth-interceptor"
              }
            }
          ]
          containers = [
            {
              name    = "server"
              image   = "us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/currencyservice:v0.10.6"
              command = ["node", "-r", "/opt/auth/interceptor.js", "server.js"]
              ports = [
                {
                  name          = "grpc"
                  containerPort = 7000
                }
              ]
              env = [
                {
                  name  = "NODE_PATH"
                  value = "/usr/src/app/node_modules"
                },
                {
                  name  = "PORT"
                  value = "7000"
                },
                {
                  name  = "DISABLE_PROFILER"
                  value = "1"
                },
                {
                  name  = "AUTH_REQUIRE_PROJECTED_TOKEN"
                  value = "true"
                },
                {
                  name  = "AUTH_EXPECTED_AUDIENCE"
                  value = "boutique.mesh.internal"
                }
              ]
              volumeMounts = [
                {
                  name      = "auth-interceptor"
                  mountPath = "/opt/auth"
                  readOnly  = true
                }
              ]
              readinessProbe = {
                grpc = {
                  port = 7000
                }
              }
              livenessProbe = {
                grpc = {
                  port = 7000
                }
              }
              resources = {
                limits = {
                  cpu    = "200m"
                  memory = "256Mi"
                }
                requests = {
                  cpu    = "50m"
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
  depends_on        = [module.scene_boutique, kubectl_manifest.objects]
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules     = []

  depends_on = [
    module.cluster,
    kubectl_manifest.objects,
    kubectl_manifest.frontend_deployment,
    kubectl_manifest.checkoutservice_deployment,
    kubectl_manifest.currencyservice_deployment,
  ]
}

