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

# Stack definition for eh1-0046 on kind.
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

resource "kubernetes_namespace_v1" "cart_store" {
  metadata {
    name = "cart-store"
    labels = {
      "living-stack"                = "primary"
      "kubernetes.io/metadata.name" = "cart-store"
    }
  }

  depends_on = [module.cluster]
}

resource "kubernetes_namespace_v1" "cart_verifier" {
  metadata {
    name = "cart-verifier"
    labels = {
      "kubernetes.io/metadata.name" = "cart-verifier"
    }
  }

  depends_on = [module.cluster]
}

# Headless multi-endpoint Redis store in cart-store namespace.
# 30 replicas ensure the DNS A record response exceeds 512 bytes, requiring TCP fallback.
resource "kubectl_manifest" "cart_store_redis" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "redis-cart"
      namespace = kubernetes_namespace_v1.cart_store.metadata[0].name
      labels = {
        app = "redis-cart-sharded"
      }
    }
    spec = {
      replicas = 30
      selector = {
        matchLabels = {
          app = "redis-cart-sharded"
        }
      }
      template = {
        metadata = {
          labels = {
            app = "redis-cart-sharded"
          }
        }
        spec = {
          containers = [
            {
              name  = "redis"
              image = "redis:alpine@sha256:9d317178eceac8454a2284a9e6df2466b93c745529947f0cd42a0fa9609d7005"
              ports = [
                {
                  containerPort = 6379
                }
              ]
              readinessProbe = {
                initialDelaySeconds = 2
                periodSeconds       = 5
                failureThreshold    = 6
                tcpSocket = {
                  port = 6379
                }
              }
              livenessProbe = {
                initialDelaySeconds = 15
                periodSeconds       = 10
                failureThreshold    = 6
                tcpSocket = {
                  port = 6379
                }
              }
              resources = {
                limits = {
                  memory = "128Mi"
                  cpu    = "500m"
                }
                requests = {
                  cpu    = "10m"
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
  depends_on        = [kubernetes_namespace_v1.cart_store]
}

resource "kubectl_manifest" "cart_store_headless_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "redis-cart-headless"
      namespace = kubernetes_namespace_v1.cart_store.metadata[0].name
    }
    spec = {
      clusterIP = "None"
      selector = {
        app = "redis-cart-sharded"
      }
      ports = [
        {
          name       = "tcp-redis"
          port       = 6379
          targetPort = 6379
        }
      ]
    }
  })
  server_side_apply = true
  depends_on        = [kubernetes_namespace_v1.cart_store]
}

resource "kubectl_manifest" "cart_store_netpol" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "redis-store-policy"
      namespace = kubernetes_namespace_v1.cart_store.metadata[0].name
    }
    spec = {
      podSelector = {
        matchLabels = {
          app = "redis-cart-sharded"
        }
      }
      policyTypes = ["Ingress"]
      ingress = [
        {
          from = [
            {
              namespaceSelector = {
                matchLabels = {
                  "kubernetes.io/metadata.name" = "boutique"
                }
              }
              podSelector = {
                matchLabels = {
                  app           = "cartservice"
                  "cart-access" = "authorized"
                }
              }
            },
            {
              namespaceSelector = {
                matchLabels = {
                  "kubernetes.io/metadata.name" = "cart-verifier"
                }
              }
            }
          ]
          ports = [
            {
              protocol = "TCP"
              port     = 6379
            }
          ]
        }
      ]
    }
  })
  server_side_apply = true
  depends_on        = [kubernetes_namespace_v1.cart_store]
}

resource "kubernetes_cluster_role_binding_v1" "cart_verifier_netpol_read" {
  metadata {
    name = "cart-verifier-view"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace_v1.cart_verifier.metadata[0].name
  }
  depends_on = [kubernetes_namespace_v1.cart_verifier]
}

resource "kubernetes_secret_v1" "cart_status_script" {
  metadata {
    name      = "cart-status-script"
    namespace = kubernetes_namespace_v1.cart_verifier.metadata[0].name
  }
  data = {
    "exporter.py" = <<-PY
      import json
      import ssl
      import threading
      import time
      import urllib.request
      import socket
      from http.server import HTTPServer, BaseHTTPRequestHandler

      state = {
          "cart_operations_healthy": False,
          "frontend_accessible": False,
          "cart_service_port_open": False
      }

      def check_netpol():
          try:
              with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
                  token = f.read().strip()
              ctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
              pol_name = "boutique-client-egress"
              target_ns = "cart-store"
              req = urllib.request.Request(
                  f"https://kubernetes.default.svc/apis/networking.k8s.io/v1/namespaces/boutique/networkpolicies/{pol_name}",
                  headers={"Authorization": f"Bearer {token}"}
              )
              with urllib.request.urlopen(req, context=ctx, timeout=3) as resp:
                  np = json.loads(resp.read().decode("utf-8"))
              has_dns_tcp = False
              has_backend_target = False
              for rule in np.get("spec", {}).get("egress", []):
                  ports = rule.get("ports", [])
                  for p in ports:
                      port_val = p.get("port")
                      proto = p.get("protocol", "TCP")
                      if (port_val == 53 or str(port_val) == "53") and proto == "TCP":
                          has_dns_tcp = True
                      if (port_val == 6379 or str(port_val) == "6379"):
                          for peer in rule.get("to", []):
                              labels = peer.get("namespaceSelector", {}).get("matchLabels", {})
                              pod_lbls = peer.get("podSelector", {}).get("matchLabels", {})
                              if (labels.get("kubernetes.io/metadata.name") == target_ns or labels.get("living-stack") == "primary"):
                                  if pod_lbls.get("app") == "redis-cart-sharded":
                                      has_backend_target = True
              return has_dns_tcp and has_backend_target
          except urllib.error.HTTPError as e:
              if e.code == 404:
                  return False
              return False
          except Exception:
              return False

      def probe_cart():
          cs_open = False
          try:
              s = socket.create_connection(("cartservice.boutique.svc.cluster.local", 7070), timeout=2)
              s.close()
              cs_open = True
          except Exception:
              cs_open = False
          state["cart_service_port_open"] = cs_open

          fe_ok = False
          try:
              with urllib.request.urlopen("http://frontend.boutique.svc.cluster.local/", timeout=3) as resp:
                  fe_ok = (resp.status == 200)
          except Exception:
              fe_ok = False
          state["frontend_accessible"] = fe_ok

          cart_healthy = False
          if check_netpol():
              try:
                  with urllib.request.urlopen("http://frontend.boutique.svc.cluster.local/cart", timeout=3) as resp:
                      if resp.status == 200:
                          cart_healthy = True
              except Exception:
                  cart_healthy = False
          state["cart_operations_healthy"] = cart_healthy

      def probe_worker():
          while True:
              probe_cart()
              time.sleep(3)

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
          server = HTTPServer(("0.0.0.0", 8080), StatusHandler)
          server.serve_forever()
    PY
  }
  depends_on = [kubernetes_namespace_v1.cart_verifier, kubernetes_cluster_role_binding_v1.cart_verifier_netpol_read]
}

resource "kubectl_manifest" "cart_status_deployment" {
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
        }
        spec = {
          volumes = [
            {
              name = "script"
              secret = {
                secretName = kubernetes_secret_v1.cart_status_script.metadata[0].name
              }
            }
          ]
          containers = [
            {
              name    = "exporter"
              image   = "python:3.13-alpine@sha256:7415fbc3c9e4979cc717d92377ab2bc7b2b4a2af1ac03cc52b5f3f88efedaf3a"
              command = ["python", "-u", "/app/exporter.py"]
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
  depends_on        = [kubernetes_secret_v1.cart_status_script]
}

resource "kubectl_manifest" "cart_status_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "cart-status"
      namespace = kubernetes_namespace_v1.cart_verifier.metadata[0].name
    }
    spec = {
      type = "ClusterIP"
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

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true

  wait             = true
  wait_for_rollout = false
  depends_on       = [module.scene_boutique, kubernetes_namespace_v1.cart_store]
}

locals {
  identity_baselines = {
    "cart-store/Deployment/redis-cart" = { api_version = "apps/v1" }
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

  depends_on = [kubectl_manifest.cart_store_redis, kubectl_manifest.objects]
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
  extra_rules     = []

  depends_on = [module.cluster, kubectl_manifest.objects]
}
