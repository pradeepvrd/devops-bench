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
  overrides = {}

  objects = {
    "boutique/Service/productcatalogservice-canary" = {
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "productcatalogservice-canary"
        namespace = "boutique"
        labels    = { app = "productcatalogservice-canary" }
      }
      spec = {
        type     = "ClusterIP"
        selector = { app = "productcatalogservice-canary" }
        ports = [
          {
            name       = "grpc"
            port       = 3551
            targetPort = 3550
          }
        ]
      }
    }

    "boutique/ReferenceGrant/gateway-to-boutique" = {
      apiVersion = "gateway.networking.k8s.io/v1beta1"
      kind       = "ReferenceGrant"
      metadata = {
        name      = "gateway-to-boutique"
        namespace = "boutique"
      }
      spec = {
        from = [
          {
            group     = "gateway.networking.k8s.io"
            kind      = "HTTPRoute"
            namespace = "gateway-infra"
          }
        ]
        to = [
          {
            group = ""
            kind  = "Service"
          }
        ]
      }
    }

    "gateway-infra/HTTPRoute/productcatalog-route" = {
      apiVersion = "gateway.networking.k8s.io/v1"
      kind       = "HTTPRoute"
      metadata = {
        name      = "productcatalog-route"
        namespace = "gateway-infra"
      }
      spec = {
        parentRefs = [
          {
            name      = "shared-gateway"
            namespace = "gateway-infra"
          }
        ]
        rules = [
          {
            matches = [
              {
                path = {
                  type  = "PathPrefix"
                  value = "/product"
                }
              }
            ]
            backendRefs = [
              {
                name      = "productcatalogservice"
                namespace = "boutique"
                port      = 3550
                weight    = 90
              },
              {
                name      = "productcatalogservice-canary"
                namespace = "boutique"
                port      = 3550
                weight    = 10
                filters = [
                  {
                    type = "ResponseHeaderModifier"
                    responseHeaderModifier = {
                      set = [
                        {
                          name  = "X-Canary-Upstream"
                          value = "boutique-canary"
                        }
                      ]
                      remove = [
                        "X-Envoy-Decorator-Operation",
                        "X-Canary-Trace-Id"
                      ]
                    }
                  }
                ]
              }
            ]
          }
        ]
      }
    }
  }
}
