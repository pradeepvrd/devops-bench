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

# Seed: faulted state.
# Configures cartservice endpoint override to redis-cart-headless.cart-store.svc.cluster.local:6379,
# seeded client-side egress NetworkPolicy with UDP-only port 53 (blocking TCP fallback on truncation)
# and drifted backend selector targeting app: redis-cart-legacy (instead of redis-cart-sharded).
locals {
  overrides = {
    service_endpoints = {
      cart_database = "redis-cart-headless.cart-store.svc.cluster.local:6379"
    }
  }

  objects = {
    "boutique/NetworkPolicy/boutique-client-egress" = {
      apiVersion = "networking.k8s.io/v1"
      kind       = "NetworkPolicy"
      metadata = {
        name      = "boutique-client-egress"
        namespace = "boutique"
      }
      spec = {
        podSelector = {
          matchLabels = {
            app = "cartservice"
          }
        }
        policyTypes = ["Egress"]
        egress = [
          {
            to = [
              {
                namespaceSelector = {
                  matchLabels = {
                    "kubernetes.io/metadata.name" = "kube-system"
                  }
                }
              }
            ]
            ports = [
              {
                protocol = "UDP"
                port     = 53
              }
            ]
          },
          {
            to = [
              {
                namespaceSelector = {
                  matchLabels = {
                    "kubernetes.io/metadata.name" = "cart-store"
                  }
                }
                podSelector = {
                  matchLabels = {
                    app = "redis-cart-legacy"
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
    }
  }
}
