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

# Preloads required container images into a kind cluster's containerd nodes.
# Supports both public upstream images (pulled via docker pull if not cached)
# and repository-vendored local generator/verifier images (built on the fly via
# docker build from their local Dockerfiles in tf/modules/living-stacks or ./oracle).

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
}

resource "null_resource" "preload" {
  triggers = {
    cluster_name    = var.cluster_name
    images          = join(",", var.images)
    import_platform = var.import_platform
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      cluster="${var.cluster_name}"
      platform="${var.import_platform}"
      module_dir="${path.module}"
      images=(${join(" ", [for img in var.images : "\"${img}\""])})

      nodes="$(kind get nodes --name "$cluster")" || {
        echo "image_preload: 'kind get nodes --name $cluster' failed; is the kind cluster up and named correctly?" >&2
        exit 1
      }
      if [ -z "$nodes" ]; then
        echo "image_preload: 'kind get nodes --name $cluster' returned no nodes" >&2
        exit 1
      fi

      for image in "$${images[@]}"; do
        if ! docker image inspect "$image" >/dev/null 2>&1; then
          case "$image" in
            devops-bench/traffic-engine:*)
              echo "image_preload: building $image from vendored streaming/tf/modules/traffic_engine"
              docker build -t "$image" "$module_dir/../../streaming/tf/modules/traffic_engine"
              ;;
            devops-bench/oltp-writer:*)
              echo "image_preload: building $image from vendored cdc/tf/modules/oltp_writer"
              docker build -t "$image" "$module_dir/../../cdc/tf/modules/oltp_writer"
              ;;
            devops-bench/eh1-*-oracle:*)
              if ! docker image inspect "devops-bench/oltp-writer:1.0.0" >/dev/null 2>&1; then
                echo "image_preload: building base devops-bench/oltp-writer:1.0.0 from vendored cdc/tf/modules/oltp_writer"
                docker build -t "devops-bench/oltp-writer:1.0.0" "$module_dir/../../cdc/tf/modules/oltp_writer"
              fi
              echo "image_preload: building $image from local ./oracle"
              docker build -t "$image" "./oracle"
              ;;
            *)
              echo "image_preload: pulling public image $image on host"
              docker pull "$image"
              ;;
          esac
        fi

        tar="$(mktemp /tmp/image-preload-XXXXXX.tar)"
        docker save "$image" -o "$tar"

        for node in $nodes; do
          echo "image_preload: importing $image into node $node"
          if ! docker exec -i "$node" ctr --namespace=k8s.io images import --digests --platform "$platform" - < "$tar"; then
            echo "image_preload: failed to import $image into node $node" >&2
            rm -f "$tar"
            exit 1
          fi
        done

        rm -f "$tar"
      done
    EOT
  }
}
