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

# seed: the fault, as scene overrides. Applied under every arm.
#
# The fault is expressed entirely through `collector_values`, the scene's own
# declared override surface, rather than by naming a scene-owned object. The
# collector's ConfigMap, Deployment and Service all belong to the
# opentelemetry-collector chart, and the scene keeps Helm as their sole owner.
#
# What it does: binds the collector's OTLP http receiver to loopback instead of
# the pod IP. The receiver still exists, still starts, and still listens on
# :4318 -- but only on 127.0.0.1, so nothing outside the collector's own network
# namespace can reach it. gRPC on :4317 keeps its default bind and is untouched.
#
# Why that is selective rather than total, which is the whole design: this scene
# does not use one transport. Measured on a scratch cluster before any of this
# was written (diagnostic 01M2HZSA8JPEB2RKDYWEA26DSP) --
#
#   http/protobuf -> :4318   checkout, flagd, load-generator, shipping
#   gRPC          -> :4317   cart, currency, frontend, payment,
#                            product-catalog, recommendation
#
# so closing :4318 silences the first group and leaves the second untouched. The
# collector stays 1/1 Ready with its liveness probe on :13133 passing, and
# checkout keeps serving requests with 0 restarts: only its telemetry stops.
#
# Why a value and not a deletion, which cost a controls round. The first version
# set `http` to null, reasoning that shop_chart filters nulls only at the top
# level so a nested null would survive yamlencode and make Helm drop the key.
# The Terraform half was right -- yamlencode does emit `"http": null`, verified
# directly -- but Helm's merge SKIPS nulls rather than deleting keys, so the
# chart's default http receiver survived and the scene was never armed. The base
# arm caught it exactly as it should: "no objective failed doing nothing: the
# scene is unarmed".
#
# A value merges normally, so the fault now arms through the same sanctioned
# override surface without any runtime patching, Job, or ConfigMap edit -- and
# therefore without the restart-propagation problem that cost eh1-0027 two
# rounds.
#
# Loopback rather than a wrong port number, deliberately. A receiver on an
# unexpected port is a loud tell: the reader compares it against the Service and
# the mismatch jumps out. `127.0.0.1:4318` keeps the port the Service targets and
# is a textbook real-world mistake -- bind to localhost instead of the pod IP --
# so the config reads as ordinary and the fault is only visible by asking where
# the clients actually connect from.
locals {
  # Kept identical in repair/main.tf. The repair replaces this whole key, so if
  # the presets were only here the oracle arm would silently re-enable the
  # host, kubelet and cluster metrics collectors and change the scene it is
  # being compared against.
  collector_presets = {
    hostMetrics    = { enabled = false }
    kubeletMetrics = { enabled = false }
    clusterMetrics = { enabled = false }
  }

  overrides = {
    collector_values = {
      presets = local.collector_presets
      config = {
        receivers = {
          otlp = {
            protocols = {
              # The default is "$${env:MY_POD_IP}:4318". A literal is used rather
              # than that expansion because $${...} in HCL is Terraform's own
              # interpolation syntax and would have to be escaped to survive.
              http = { endpoint = "127.0.0.1:4318" }
            }
          }
        }
      }
    }
  }

  objects = {}
}
