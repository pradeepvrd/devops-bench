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

# Seed: faulted state for eh1-0063.
# 1. HTTPRoute in namespace gateway-infra matches lowercase x-payment-tier (Gateway API Exact match is case-sensitive).
# 2. Service/paymentservice-v2 in namespace boutique omits appProtocol: kubernetes.io/h2c on port 50051.
locals {
  overrides = {}

  objects = {
    "boutique/Service/paymentservice-v2" = {
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "paymentservice-v2"
        namespace = "boutique"
      }
      spec = {
        type     = "ClusterIP"
        selector = { app = "paymentservice-v2" }
        ports = [
          {
            name       = "http-payment"
            port       = 50051
            targetPort = 50051
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

    "gateway-infra/HTTPRoute/checkout-route" = {
      apiVersion = "gateway.networking.k8s.io/v1"
      kind       = "HTTPRoute"
      metadata = {
        name      = "checkout-route"
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
                headers = [
                  {
                    name  = "x-payment-tier"
                    value = "premium"
                    type  = "Exact"
                  }
                ]
              }
            ]
            backendRefs = [
              {
                name      = "paymentservice-v2"
                namespace = "boutique"
                port      = 50051
              }
            ]
          },
          {
            backendRefs = [
              {
                name      = "paymentservice"
                namespace = "boutique"
                port      = 50051
              }
            ]
          }
        ]
      }
    }
  }
}
