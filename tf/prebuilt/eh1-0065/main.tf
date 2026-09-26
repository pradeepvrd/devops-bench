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

# Stack for eh1-0065 (otel-demo cardinality spike + memory limiter inversion)

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
  ns = "otel-demo"

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

  edit_namespaces = [local.ns]
}

resource "kubernetes_namespace_v1" "data_platform" {
  metadata { name = "data-platform" }
  depends_on = [module.cluster]
}

module "kafka_bus" {
  source = "../../modules/living-stacks/streaming/tf/modules/kafka_strimzi"

  namespace             = kubernetes_namespace_v1.data_platform.metadata[0].name
  system                = "primary"
  kubeconfig            = var.kubeconfig_path
  create_cdc_topics     = false
  nodepool_replicas     = 1
  nodepool_storage_type = "ephemeral"
  nodepool_cpu          = "200m"
  nodepool_memory       = "768Mi"
  kafka_ready_timeout   = "420s"

  depends_on = [module.cluster]
}

module "scene_otel_demo" {
  source = "../../modules/living-stacks/otel-demo/tf/scene"

  kubeconfig      = var.kubeconfig_path
  namespace       = local.ns
  kafka_bootstrap = module.kafka_bus.kafka_bootstrap
  kafka_namespace = module.kafka_bus.namespace
  chart_version   = "0.41.0"
  load_gen_vus    = 10
  scenario        = "baseline"

  collector_values = {
    presets = {
      hostMetrics    = { enabled = false }
      kubeletMetrics = { enabled = false }
      clusterMetrics = { enabled = false }
    }
  }

  component_resources = {
    for name in ["quote", "shipping", "checkout", "frontend", "email"] : name => {
      requests = { cpu = "100m", memory = "100Mi" }
      limits   = { memory = "256Mi" }
    }
  }

  depends_on = [module.kafka_bus, module.image_preload]
}

resource "kubectl_manifest" "objects" {
  for_each = local.objects

  yaml_body         = yamlencode(each.value)
  server_side_apply = true
  force_conflicts   = true
  wait              = true
  wait_for_rollout  = false

  depends_on = [module.scene_otel_demo]
}

resource "kubernetes_config_map_v1" "trace_sink_config" {
  metadata {
    name      = "trace-sink-config"
    namespace = local.ns
  }
  data = {
    "config.yaml" = <<-YAML
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
      exporters:
        file:
          path: /data/traces.json
        debug:
          verbosity: basic
      service:
        telemetry:
          metrics:
            readers:
              - pull:
                  exporter:
                    prometheus:
                      host: 0.0.0.0
                      port: 8888
        pipelines:
          traces:
            receivers: [otlp]
            exporters: [file, debug]
    YAML
  }
  depends_on = [module.scene_otel_demo]
}

resource "kubernetes_service_account_v1" "trace_sink_sa" {
  metadata {
    name      = "trace-sink-sa"
    namespace = local.ns
  }
  depends_on = [module.scene_otel_demo]
}

resource "kubernetes_role_v1" "trace_sink_role" {
  metadata {
    name      = "trace-sink-role"
    namespace = local.ns
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps", "pods", "services", "endpoints"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch"]
  }
  depends_on = [module.scene_otel_demo]
}

resource "kubernetes_role_binding_v1" "trace_sink_rb" {
  metadata {
    name      = "trace-sink-rb"
    namespace = local.ns
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.trace_sink_role.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.trace_sink_sa.metadata[0].name
    namespace = local.ns
  }
  depends_on = [kubernetes_service_account_v1.trace_sink_sa, kubernetes_role_v1.trace_sink_role]
}

resource "kubernetes_secret_v1" "trace_sink_status_script" {
  metadata {
    name      = "trace-sink-status-script"
    namespace = local.ns
  }
  data = {
    "status_server.py" = <<-PY
      import json
      import os
      import re
      import ssl
      import threading
      import time
      import urllib.request
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
      CA_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      K8S_API = "https://kubernetes.default.svc"

      COLLECTOR_HEALTH_URL = "http://otel-collector.otel-demo.svc.cluster.local:13133/"
      COLLECTOR_METRICS_URL = "http://otel-collector.otel-demo.svc.cluster.local:8888/metrics"
      TRACES_FILE = "/data/traces.json"

      state = {
          "traces_receiving": False,
          "checkout_and_payment_traces_delivered": False,
          "collector_gateway_healthy": False,
      }

      latched = {
          "traces_receiving": False,
          "checkout_and_payment_traces_delivered": False,
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
          try:
              req = urllib.request.Request(
                  f"{K8S_API}{url_path}",
                  headers={"Authorization": f"Bearer {token}", "Accept": "application/json"}
              )
              with urllib.request.urlopen(req, context=ctx, timeout=2.0) as resp:
                  return json.loads(resp.read().decode("utf-8"))
          except Exception:
              return None

      def get_collector_pod_info(token, ctx):
          pods = k8s_get("/api/v1/namespaces/otel-demo/pods", token, ctx)
          if pods:
              for item in pods.get("items", []):
                  meta = item.get("metadata", {})
                  if meta.get("deletionTimestamp"):
                      continue
                  if "otel-collector" in meta.get("name", ""):
                      status = item.get("status", {})
                      phase = status.get("phase")
                      pod_ip = status.get("podIP")
                      c_statuses = status.get("containerStatuses", [])
                      ready = bool(c_statuses and all(c.get("ready") for c in c_statuses))
                      if phase == "Running" and pod_ip:
                          return pod_ip, ready
          return None, False

      def check_collector_health(pod_ip):
          urls = [COLLECTOR_HEALTH_URL]
          if pod_ip:
              urls.insert(0, f"http://{pod_ip}:13133/")
          for u in urls:
              try:
                  req = urllib.request.Request(u)
                  with urllib.request.urlopen(req, timeout=2.0) as resp:
                      if resp.status == 200:
                          return True
              except Exception:
                  pass
          return False

      def check_traces_file():
          if not os.path.exists(TRACES_FILE):
              return False, False
          try:
              file_size = os.path.getsize(TRACES_FILE)
              if file_size == 0:
                  return False, False
              read_size = min(file_size, 1000000)
              with open(TRACES_FILE, "rb") as f:
                  if file_size > read_size:
                      f.seek(file_size - read_size)
                  chunk = f.read().decode("utf-8", errors="ignore")
              has_traces = len(chunk) > 0 and "resourceSpans" in chunk
              has_checkout = "checkout" in chunk or "cart" in chunk
              has_payment = "payment" in chunk or "frontend" in chunk
              return has_traces, (has_checkout and has_payment)
          except Exception:
              return False, False

      def check_k8s_hops():
          token, ctx = get_k8s_ctx()
          if not token or not ctx:
              return False, False, False, None, False
          limiter_ok = False
          cardinality_ok = False
          mem_limit_ok = False

          cm = k8s_get("/api/v1/namespaces/otel-demo/configmaps/otel-collector-config", token, ctx)
          if cm:
              relay = cm.get("data", {}).get("relay", "")
              # Memory limiter must not be inverted (limit >= 70% or limit_mib >= 250)
              m_pct = re.search(r"limit_percentage:\s*(\d+)", relay)
              m_mib = re.search(r"limit_mib:\s*(\d+)", relay)
              if m_pct and int(m_pct.group(1)) >= 70:
                  limiter_ok = True
              elif m_mib and int(m_mib.group(1)) >= 250:
                  limiter_ok = True
              # High-cardinality session_id upsert must be removed or switched to delete
              if "unbounded-session-cardinality-stream" not in relay or re.search(r"key:\s*session_id[\s\S]{0,80}?action:\s*delete", relay):
                  cardinality_ok = True

          dep = k8s_get("/apis/apps/v1/namespaces/otel-demo/deployments/otel-collector", token, ctx)
          if dep:
              containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
              if containers:
                  mem_lim = containers[0].get("resources", {}).get("limits", {}).get("memory", "")
                  if mem_lim in ("384Mi", "512Mi"):
                      mem_limit_ok = True

          pod_ip, pod_ready = get_collector_pod_info(token, ctx)
          return (limiter_ok and cardinality_ok), mem_limit_ok, pod_ip, pod_ready

      def worker_loop():
          while True:
              try:
                  limiter_ok, mem_limit_ok, pod_ip, pod_ready = check_k8s_hops()
                  health = check_collector_health(pod_ip)
                  has_traces, has_checkout_payment = check_traces_file()
                  collector_ready = bool(pod_ready and health)
                  all_valid = bool(limiter_ok and mem_limit_ok and collector_ready)

                  if not all_valid:
                      latched["traces_receiving"] = False
                      latched["checkout_and_payment_traces_delivered"] = False
                  elif has_traces:
                      latched["traces_receiving"] = True
                      latched["checkout_and_payment_traces_delivered"] = True

                  state["collector_gateway_healthy"] = bool(collector_ready and limiter_ok and mem_limit_ok)
                  state["traces_receiving"] = bool(latched["traces_receiving"] or has_traces)
                  state["checkout_and_payment_traces_delivered"] = bool(latched["checkout_and_payment_traces_delivered"] and all_valid)
              except Exception as exc:
                  print(f"worker error: {exc}", flush=True)
              time.sleep(1.0)

      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path == "/status":
                  payload = json.dumps(state).encode("utf-8")
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(payload)))
                  self.end_headers()
                  self.wfile.write(payload)
              elif self.path in ("/healthz", "/readyz"):
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", "19")
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
          ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PY
  }
  depends_on = [module.scene_otel_demo]
}

resource "kubectl_manifest" "trace_sink_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "trace-sink"
      namespace = local.ns
    }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "trace-sink" } }
      template = {
        metadata = { labels = { app = "trace-sink" } }
        spec = {
          serviceAccountName = kubernetes_service_account_v1.trace_sink_sa.metadata[0].name
          volumes = [
            {
              name     = "shared-data"
              emptyDir = {}
            },
            {
              name      = "config"
              configMap = { name = kubernetes_config_map_v1.trace_sink_config.metadata[0].name }
            },
            {
              name   = "script"
              secret = { secretName = kubernetes_secret_v1.trace_sink_status_script.metadata[0].name }
            }
          ]
          containers = [
            {
              name  = "sink"
              image = "otel/opentelemetry-collector-contrib:0.156.0"
              args  = ["--config=/conf/config.yaml"]
              ports = [
                { name = "grpc-otlp", containerPort = 4317 },
                { name = "http-otlp", containerPort = 4318 },
                { name = "metrics", containerPort = 8888 }
              ]
              volumeMounts = [
                { name = "config", mountPath = "/conf", readOnly = true },
                { name = "shared-data", mountPath = "/data" }
              ]
              resources = {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
              }
            },
            {
              name    = "status"
              image   = "python:3.11-slim"
              command = ["python3", "-u", "/app/status_server.py"]
              ports   = [{ name = "http-status", containerPort = 8080 }]
              volumeMounts = [
                { name = "script", mountPath = "/app", readOnly = true },
                { name = "shared-data", mountPath = "/data", readOnly = true }
              ]
              resources = {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { memory = "128Mi" }
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
  depends_on        = [kubernetes_config_map_v1.trace_sink_config, kubernetes_secret_v1.trace_sink_status_script, kubernetes_role_binding_v1.trace_sink_rb]
}

resource "kubectl_manifest" "trace_sink_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "trace-sink"
      namespace = local.ns
    }
    spec = {
      type     = "ClusterIP"
      selector = { app = "trace-sink" }
      ports = [
        { name = "grpc-otlp", port = 4317, targetPort = 4317 },
        { name = "http-otlp", port = 4318, targetPort = 4318 },
        { name = "http-status", port = 8080, targetPort = 8080 },
        { name = "metrics", port = 8888, targetPort = 8888 }
      ]
    }
  })
  server_side_apply = true
  force_conflicts   = true
  depends_on        = [kubectl_manifest.trace_sink_deployment]
}

module "bench_agent" {
  source = "../../modules/living-stacks/platform/bench_agent"

  edit_namespaces = local.edit_namespaces
  cluster_read    = true
  extra_rules     = []

  depends_on = [module.cluster, kubectl_manifest.objects]
}

resource "kubernetes_cluster_role_v1" "bench_agent_crd" {
  metadata {
    name = "bench-agent-crd-eh1-0065"
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["services", "configmaps", "pods", "pods/log", "namespaces", "endpoints", "secrets", "events"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  depends_on = [module.bench_agent]
}

resource "kubernetes_cluster_role_binding_v1" "bench_agent_crd" {
  metadata {
    name = "bench-agent-crd-eh1-0065"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.bench_agent_crd.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "bench-agent"
    namespace = "bench-system"
  }
  depends_on = [module.bench_agent, kubernetes_cluster_role_v1.bench_agent_crd]
}
