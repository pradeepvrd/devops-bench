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
    "app.kubernetes.io/name"       = "gateway-api"
    "app.kubernetes.io/managed-by" = "living-stacks"
    "living-stack-component"       = "gateway-api"
    "living-stack"                 = var.system
  }

  fixture_labels = {
    "app.kubernetes.io/name"       = "gateway-controller-fixture"
    "app.kubernetes.io/managed-by" = "living-stacks"
    "living-stack-component"       = "gateway-api"
    "living-stack"                 = var.system
  }

  standard_crds = [
    "gatewayclasses.gateway.networking.k8s.io",
    "gateways.gateway.networking.k8s.io",
    "httproutes.gateway.networking.k8s.io",
    "grpcroutes.gateway.networking.k8s.io",
    "referencegrants.gateway.networking.k8s.io"
  ]

  vendored_crds_manifest = "${path.module}/manifests/standard-install-v1.2.0.yaml"

  crds_manifest_source = (
    var.crds_manifest_source != null && var.crds_manifest_source != ""
    ? var.crds_manifest_source
    : (var.crds_manifest_url != null && var.crds_manifest_url != ""
      ? var.crds_manifest_url
    : local.vendored_crds_manifest)
  )
  kubeconfig_arg = var.kubeconfig != "" ? "--kubeconfig ${var.kubeconfig}" : ""

  default_listeners = [
    {
      name                    = "http"
      protocol                = "HTTP"
      port                    = var.gateway_port
      hostname                = null
      allowed_routes_selector = null
    }
  ]

  raw_listeners = (
    var.listeners != null && length(var.listeners) > 0
    ? var.listeners
    : (var.gateway_listeners != null && length(var.gateway_listeners) > 0
      ? var.gateway_listeners
    : local.default_listeners)
  )

  gateway_listeners = [
    for l in local.raw_listeners : merge(
      {
        name     = l.name
        protocol = l.protocol
        port     = l.port
        allowedRoutes = {
          namespaces = merge(
            { from = try(length(l.allowed_routes_selector), 0) > 0 ? "Selector" : "All" },
            try(length(l.allowed_routes_selector), 0) > 0 ? {
              selector = {
                matchLabels = try(l.allowed_routes_selector.matchLabels, l.allowed_routes_selector)
              }
            } : {}
          )
        }
      },
      l.hostname != null && l.hostname != "" ? { hostname = l.hostname } : {}
    )
  ]
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = var.gateway_namespace
    labels = local.labels
  }
}

resource "null_resource" "install_crds" {
  count = var.install_crds ? 1 : 0

  triggers = {
    gateway_api_version = var.gateway_api_version
    manifest_source     = local.crds_manifest_source
    kubeconfig          = var.kubeconfig
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubectl ${local.kubeconfig_arg} apply --server-side -f "${local.crds_manifest_source}"
    EOT
  }
}

resource "null_resource" "wait_for_crds" {
  count      = var.install_crds ? 1 : 0
  depends_on = [null_resource.install_crds]

  triggers = {
    gateway_api_version = var.gateway_api_version
    kubeconfig          = var.kubeconfig
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      for crd in ${join(" ", local.standard_crds)}; do
        kubectl ${local.kubeconfig_arg} wait --for=condition=Established "crd/$crd" --timeout=${var.crds_ready_timeout}
      done
    EOT
  }
}

resource "kubectl_manifest" "gateway_class" {
  count      = var.install_shared_gateway ? 1 : 0
  depends_on = [null_resource.wait_for_crds]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name   = var.gateway_class_name
      labels = local.labels
    }
    spec = {
      controllerName = var.controller_name
    }
  })

  force_new = false
}

resource "kubectl_manifest" "shared_gateway" {
  count      = var.install_shared_gateway ? 1 : 0
  depends_on = [null_resource.wait_for_crds, kubectl_manifest.gateway_class, kubernetes_namespace_v1.this]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.gateway_name
      namespace = var.gateway_namespace
      labels    = local.labels
    }
    spec = {
      gatewayClassName = var.gateway_class_name
      listeners        = local.gateway_listeners
    }
  })

  force_new = false
}

resource "kubernetes_service_account_v1" "controller_fixture" {
  count = var.install_controller_fixture ? 1 : 0

  metadata {
    name      = "gateway-controller-fixture"
    namespace = var.gateway_namespace
    labels    = local.fixture_labels
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_cluster_role_v1" "controller_fixture" {
  count = var.install_controller_fixture ? 1 : 0

  metadata {
    name   = "gateway-controller-fixture-${var.gateway_namespace}"
    labels = local.fixture_labels
  }

  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources = [
      "gatewayclasses",
      "gatewayclasses/status",
      "gateways",
      "gateways/status",
      "httproutes",
      "httproutes/status",
      "grpcroutes",
      "grpcroutes/status",
      "referencegrants",
      "referencegrants/status"
    ]
    verbs = ["get", "list", "watch", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["services", "endpoints", "pods", "namespaces", "configmaps"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "controller_fixture" {
  count = var.install_controller_fixture ? 1 : 0

  metadata {
    name   = "gateway-controller-fixture-${var.gateway_namespace}"
    labels = local.fixture_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.controller_fixture[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.controller_fixture[0].metadata[0].name
    namespace = var.gateway_namespace
  }
}

resource "kubernetes_service_v1" "shared_gateway" {
  count = var.install_controller_fixture ? 1 : 0

  metadata {
    name      = var.gateway_name
    namespace = var.gateway_namespace
    labels    = local.labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "gateway-controller-fixture"
    }

    dynamic "port" {
      for_each = local.gateway_listeners
      content {
        name        = port.value.name
        port        = port.value.port
        target_port = 8080
        protocol    = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_config_map_v1" "fixture_script" {
  count = var.install_controller_fixture ? 1 : 0

  metadata {
    name      = "gateway-controller-fixture-script"
    namespace = var.gateway_namespace
    labels    = local.fixture_labels
  }

  data = {
    "reconciler.py" = <<-PY
      import http.server
      import json
      import socketserver
      import sys

      PORT = 8080

      class FixtureHandler(http.server.SimpleHTTPRequestHandler):
          def do_GET(self):
              if self.path in ("/healthz", "/readyz", "/status"):
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.end_headers()
                  self.wfile.write(json.dumps({"status": "healthy", "controller": "gateway-fixture"}).encode())
                  return
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.end_headers()
              self.wfile.write(b"gateway-controller-fixture active\n")

          def log_message(self, format, *args):
              sys.stdout.write(f"gateway-fixture: {format % args}\n")
              sys.stdout.flush()

      print(f"Starting Gateway API controller fixture server on port {PORT}...")
      with socketserver.TCPServer(("", PORT), FixtureHandler) as httpd:
          httpd.serve_forever()
    PY
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_deployment_v1" "controller_fixture" {
  count = var.install_controller_fixture ? 1 : 0

  metadata {
    name      = "gateway-controller-fixture"
    namespace = var.gateway_namespace
    labels    = local.fixture_labels
  }

  spec {
    replicas = var.controller_replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "gateway-controller-fixture"
      }
    }

    template {
      metadata {
        labels = local.fixture_labels
        annotations = {
          "checksum/script" = sha256(kubernetes_config_map_v1.fixture_script[0].data["reconciler.py"])
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.controller_fixture[0].metadata[0].name

        volume {
          name = "script-vol"
          config_map {
            name = kubernetes_config_map_v1.fixture_script[0].metadata[0].name
          }
        }

        container {
          name  = "controller"
          image = var.controller_image

          command = ["python3", "/opt/fixture/reconciler.py"]

          volume_mount {
            name       = "script-vol"
            mount_path = "/opt/fixture"
            read_only  = true
          }

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_cluster_role_binding_v1.controller_fixture,
    kubernetes_config_map_v1.fixture_script
  ]
}
