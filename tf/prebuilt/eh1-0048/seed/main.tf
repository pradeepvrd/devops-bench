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

# Seed: faulted state for eh1-0048.
# 1. ReferenceGrant in namespace boutique only permits kind: HTTPRoute from gateway-infra, omitting GRPCRoute.
# 2. GRPCRoute in namespace gateway-infra routes to Service/checkoutservice in namespace boutique.
locals {
  overrides = {}

  objects = {
    "boutique/Service/checkoutservice" = {
      apiVersion = "v1"
      kind       = "Service"
      metadata = {
        name      = "checkoutservice"
        namespace = "boutique"
      }
      spec = {
        type     = "ClusterIP"
        selector = { app = "checkoutservice" }
        ports = [
          {
            name       = "grpc"
            port       = 5050
            targetPort = 5050
          },
          {
            name        = "grpc-checkout"
            port        = 50051
            targetPort  = 50051
            appProtocol = "grpc"
          }
        ]
      }
    }

    "boutique/ReferenceGrant/allow-gateway-to-checkout" = {
      apiVersion = "gateway.networking.k8s.io/v1beta1"
      kind       = "ReferenceGrant"
      metadata = {
        name      = "allow-gateway-to-checkout"
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
            name  = "checkoutservice"
          }
        ]
      }
    }

    "gateway-infra/GRPCRoute/checkout-route" = {
      apiVersion = "gateway.networking.k8s.io/v1"
      kind       = "GRPCRoute"
      metadata = {
        name      = "checkout-route"
        namespace = "gateway-infra"
      }
      spec = {
        parentRefs = [
          {
            name        = "shared-gateway"
            namespace   = "gateway-infra"
            sectionName = "grpc-checkout"
          }
        ]
        rules = [
          {
            backendRefs = [
              {
                name      = "checkoutservice"
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
