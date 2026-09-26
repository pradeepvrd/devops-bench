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

# seed: the fault, as scene overrides and objects. Applied under every arm.
locals {
  overrides = {}

  objects = {
    "streaming/Secret/kafka-indexer-credentials" = {
      apiVersion = "v1"
      kind       = "Secret"
      metadata = {
        name      = "kafka-indexer-credentials"
        namespace = "streaming"
      }
      type = "Opaque"
      stringData = {
        "sasl.username" = "indexer"
        "sasl.password" = "keda-secure-indexer-pass"
      }
    }

    "streaming/TriggerAuthentication/order-indexer-auth" = {
      apiVersion = "keda.sh/v1alpha1"
      kind       = "TriggerAuthentication"
      metadata = {
        name      = "order-indexer-auth"
        namespace = "streaming"
      }
      spec = {
        secretTargetRef = [
          {
            parameter = "sasl"
            name      = "kafka-indexer-credentials"
            key       = "sasl.username"
          },
          {
            parameter = "username"
            name      = "kafka-indexer-credentials"
            key       = "sasl.username"
          },
          {
            parameter = "password"
            name      = "kafka-indexer-credentials"
            key       = "password" # Hop 1 fault: key drift from sasl.password to password
          }
        ]
      }
    }

    "streaming/LimitRange/streaming-limit-range" = {
      apiVersion = "v1"
      kind       = "LimitRange"
      metadata = {
        name      = "streaming-limit-range"
        namespace = "streaming"
      }
      spec = {
        limits = [
          {
            type = "Container"
            default = {
              cpu    = "2000m"
              memory = "4Gi"
            }
            defaultRequest = {
              cpu    = "1500m"
              memory = "3Gi"
            }
          }
        ]
      }
    }

    "streaming/ResourceQuota/streaming-quota" = {
      apiVersion = "v1"
      kind       = "ResourceQuota"
      metadata = {
        name      = "streaming-quota"
        namespace = "streaming"
      }
      spec = {
        hard = {
          "requests.cpu"    = "6000m"
          "requests.memory" = "10Gi"
          "limits.cpu"      = "12000m"
          "limits.memory"   = "20Gi"
          "pods"            = "30"
        }
      }
    }

    "streaming/Deployment/order-indexer" = {
      apiVersion = "apps/v1"
      kind       = "Deployment"
      metadata = {
        name      = "order-indexer"
        namespace = "streaming"
        labels = {
          app = "order-indexer"
        }
      }
      spec = {
        replicas = 0
        selector = {
          matchLabels = {
            app = "order-indexer"
          }
        }
        template = {
          metadata = {
            labels = {
              app = "order-indexer"
            }
          }
          spec = {
            initContainers = [
              {
                name    = "init-schema-cache"
                image   = "python:3.11-slim"
                command = ["python3", "-c", "import time; time.sleep(1); print('schema cache initialized')"]
                # Hop 2 fault: omits explicit resources, so LimitRange injects 500m CPU / 1Gi memory
              }
            ]
            containers = [
              {
                name    = "indexer"
                image   = "python:3.11-slim"
                command = ["python3", "-u", "-c", <<-PY
import http.server
import json
import socket
import socketserver

def count_active_workers():
    try:
        infos = socket.getaddrinfo(
            'order-indexer-headless.streaming.svc.cluster.local',
            8080,
            family=socket.AF_INET,
            type=socket.SOCK_STREAM,
        )
        return len({r[4][0] for r in infos})
    except Exception:
        return 1

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ('/status', '/status/'):
            workers = count_active_workers()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            if workers >= 4:
                resp = {"status": "ok", "state": "processing", "active_workers": workers, "unconsumed_lag": 0}
            else:
                resp = {"status": "degraded", "state": "degraded_underprovisioned", "active_workers": workers, "unconsumed_lag": 18420}
            self.wfile.write(json.dumps(resp).encode('utf-8'))
        elif self.path in ('/healthz', '/healthz/'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'ok')
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(('0.0.0.0', 8080), Handler) as httpd:
    httpd.serve_forever()
PY
                ]
                ports = [
                  {
                    name          = "http"
                    containerPort = 8080
                  }
                ]
                env = [
                  {
                    name  = "KAFKA_BOOTSTRAP_SERVERS"
                    value = "kafka-kafka-bootstrap.streaming.svc:9092"
                  },
                  {
                    name  = "KAFKA_TOPIC"
                    value = "events.raw"
                  },
                  {
                    name  = "KAFKA_CONSUMER_GROUP"
                    value = "order-indexer-cg"
                  }
                ]
                resources = {
                  requests = {
                    cpu    = "100m"
                    memory = "128Mi"
                  }
                  limits = {
                    cpu    = "200m"
                    memory = "256Mi"
                  }
                }
              }
            ]
          }
        }
      }
    }

    "streaming/Service/order-indexer" = {
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "order-indexer"
        namespace = "streaming"
        labels = {
          app = "order-indexer"
        }
      }
      spec = {
        type = "ClusterIP"
        selector = {
          app = "order-indexer"
        }
        ports = [
          {
            name       = "http"
            port       = 8080
            targetPort = 8080
          }
        ]
      }
    }

    "streaming/Service/order-indexer-headless" = {
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "order-indexer-headless"
        namespace = "streaming"
        labels = {
          app = "order-indexer"
        }
      }
      spec = {
        clusterIP = "None"
        selector = {
          app = "order-indexer"
        }
        ports = [
          {
            name       = "http"
            port       = 8080
            targetPort = 8080
          }
        ]
      }
    }

    "streaming/ScaledObject/order-indexer-scaler" = {
      apiVersion = "keda.sh/v1alpha1"
      kind       = "ScaledObject"
      metadata = {
        name      = "order-indexer-scaler"
        namespace = "streaming"
      }
      spec = {
        scaleTargetRef = {
          apiVersion = "apps/v1"
          kind       = "Deployment"
          name       = "order-indexer"
        }
        minReplicaCount = 0
        maxReplicaCount = 4
        pollingInterval = 5
        cooldownPeriod  = 300
        triggers = [
          {
            type = "kafka"
            metadata = {
              bootstrapServers  = "kafka-kafka-bootstrap.streaming.svc:9092"
              consumerGroup     = "order-indexer-legacy"
              topic             = "events.raw"
              lagThreshold      = "5"
              offsetResetPolicy = "earliest"
            }
            authenticationRef = {
              name = "order-indexer-auth"
            }
          }
        ]
      }
    }
  }
}
