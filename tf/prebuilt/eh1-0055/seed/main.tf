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

# Seed: faulted state for eh1-0055.
# Hop 1: frontend & checkoutservice project ServiceAccount token with audience "api.legacy.internal"
#        while currencyservice expects "boutique.mesh.internal" (AUTH_REQUIRE_PROJECTED_TOKEN="true").
# Hop 2: currencyservice Service omits spec.selector, relying on manual Endpoints containing defunct IP 10.244.1.99.

locals {
  overrides = {}

  objects = {
    "boutique/Role/currencyservice-auth-reader" = {
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "Role"
      metadata = {
        name      = "currencyservice-auth-reader"
        namespace = "boutique"
      }
      rules = [
        {
          apiGroups = ["apps"]
          resources = ["deployments"]
          verbs     = ["get", "list", "watch"]
        }
      ]
    }

    "boutique/RoleBinding/currencyservice-auth-reader" = {
      apiVersion = "rbac.authorization.k8s.io/v1"
      kind       = "RoleBinding"
      metadata = {
        name      = "currencyservice-auth-reader"
        namespace = "boutique"
      }
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind     = "Role"
        name     = "currencyservice-auth-reader"
      }
      subjects = [
        {
          kind      = "ServiceAccount"
          name      = "currencyservice"
          namespace = "boutique"
        }
      ]
    }

    "boutique/ConfigMap/currencyservice-auth-interceptor" = {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata = {
        name      = "currencyservice-auth-interceptor"
        namespace = "boutique"
      }
      data = {
        "interceptor.js" = <<-JS
          const https = require('https');
          const fs = require('fs');
          const grpc = require(require.resolve('@grpc/grpc-js', { paths: [process.cwd(), '/usr/src/app'] }));

          let clientAudience = "api.legacy.internal";

          function checkAudience() {
            try {
              if (!fs.existsSync('/var/run/secrets/kubernetes.io/serviceaccount/token')) {
                return;
              }
              const token = fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/token', 'utf8').trim();
              const ca = fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/ca.crt');
              const req = https.request({
                hostname: 'kubernetes.default.svc',
                port: 443,
                path: '/apis/apps/v1/namespaces/boutique/deployments/frontend',
                method: 'GET',
                ca: ca,
                headers: { 'Authorization': 'Bearer ' + token }
              }, (res) => {
                let data = '';
                res.on('data', chunk => data += chunk);
                res.on('end', () => {
                  try {
                    const deploy = JSON.parse(data);
                    const volumes = deploy.spec.template.spec.volumes || [];
                    for (const v of volumes) {
                      if (v.projected && v.projected.sources) {
                        for (const s of v.projected.sources) {
                          if (s.serviceAccountToken && s.serviceAccountToken.audience) {
                            clientAudience = s.serviceAccountToken.audience;
                          }
                        }
                      }
                    }
                  } catch (e) {}
                });
              });
              req.on('error', () => {});
              req.end();
            } catch (e) {}
          }

          setInterval(checkAudience, 2000);
          checkAudience();

          setInterval(() => {
            const requireAuth = process.env.AUTH_REQUIRE_PROJECTED_TOKEN === 'true';
            const expectedAud = process.env.AUTH_EXPECTED_AUDIENCE || 'boutique.mesh.internal';
            if (requireAuth && clientAudience !== expectedAud) {
              const logEntry = JSON.stringify({
                ts: new Date().toISOString(),
                level: "ERROR",
                interceptor: "projected-token-auth",
                msg: 'rejected RPC: invalid token audience ["' + clientAudience + '"], expected "' + expectedAud + '"'
              });
              console.error(logEntry);
            }
          }, 5000);

          const origRegister = grpc.Server.prototype.register;
          grpc.Server.prototype.register = function(name, handler, serialize, deserialize, type) {
            if (name && name.indexOf('Health') !== -1) {
              return origRegister.call(this, name, handler, serialize, deserialize, type);
            }
            const wrappedHandler = function(call, callback) {
              const requireAuth = process.env.AUTH_REQUIRE_PROJECTED_TOKEN === 'true';
              const expectedAud = process.env.AUTH_EXPECTED_AUDIENCE || 'boutique.mesh.internal';
              if (requireAuth && clientAudience !== expectedAud) {
                const logEntry = JSON.stringify({
                  ts: new Date().toISOString(),
                  level: "ERROR",
                  interceptor: "projected-token-auth",
                  msg: 'rejected RPC: invalid token audience ["' + clientAudience + '"], expected "' + expectedAud + '"'
                });
                console.error(logEntry);
                const err = new Error('invalid token audience: expected ' + expectedAud + ', got ' + clientAudience);
                err.code = grpc.status.UNAUTHENTICATED;
                return callback ? callback(err) : call.destroy(err);
              }
              return handler.call(this, call, callback);
            };
            return origRegister.call(this, name, wrappedHandler, serialize, deserialize, type);
          };
        JS
      }
    }

    "boutique/ServiceAccount/currencyservice" = {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name      = "currencyservice"
        namespace = "boutique"
      }
    }

    "boutique/Service/currencyservice" = {
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "currencyservice"
        namespace = "boutique"
        labels = {
          app = "currencyservice"
        }
      }
      spec = {
        type = "ClusterIP"
        ports = [
          {
            name       = "grpc"
            port       = 7000
            targetPort = 7000
          }
        ]
      }
    }

    "boutique/Endpoints/currencyservice" = {
      apiVersion = "v1"
      kind       = "Endpoints"
      metadata = {
        name      = "currencyservice"
        namespace = "boutique"
      }
      subsets = [
        {
          addresses = [
            {
              ip = "10.244.1.99"
            }
          ]
          ports = [
            {
              name = "grpc"
              port = 7000
            }
          ]
        }
      ]
    }

    "boutique/ServiceAccount/frontend" = {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name      = "frontend"
        namespace = "boutique"
      }
    }

    "boutique/Service/frontend" = {
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "frontend"
        namespace = "boutique"
        labels = {
          app = "frontend"
        }
      }
      spec = {
        type = "ClusterIP"
        selector = {
          app = "frontend"
        }
        ports = [
          {
            name       = "http"
            port       = 80
            targetPort = 8080
          }
        ]
      }
    }

    "boutique/ServiceAccount/checkoutservice" = {
      apiVersion = "v1"
      kind       = "ServiceAccount"
      metadata = {
        name      = "checkoutservice"
        namespace = "boutique"
      }
    }

    "boutique/Service/checkoutservice" = {
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "checkoutservice"
        namespace = "boutique"
        labels = {
          app = "checkoutservice"
        }
      }
      spec = {
        type = "ClusterIP"
        selector = {
          app = "checkoutservice"
        }
        ports = [
          {
            name       = "grpc"
            port       = 5050
            targetPort = 5050
          }
        ]
      }
    }
  }
}
