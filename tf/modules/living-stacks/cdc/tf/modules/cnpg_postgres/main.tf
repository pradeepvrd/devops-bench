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

# CNPG operator (helm chart, native fit) + the "shop" Cluster CR (no native
# Terraform resource for postgresql.cnpg.io/v1 Cluster in this codebase's
# provider set, so it goes through null_resource + kubectl, matching
# docs/terraform-scene-layout.md section 2/4) + the cdc-grant-select Job
# (native kubernetes_job_v1 with wait_for_completion, per section 4's own
# call on this exact step).

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    kubernetes = {
      # wait_for_completion on kubernetes_job_v1 requires >= 2.7.0.
      source  = "hashicorp/kubernetes"
      version = ">= 2.7.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}

locals {
  # Fixed, not a variable: stack.sh hardcodes CLUSTER_NAME="shop" and never
  # overrides it, so there is nothing to make configurable here.
  cluster_name = "shop"
}

resource "helm_release" "cnpg" {
  count = var.install_operator ? 1 : 0

  name             = "cnpg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  version          = var.cnpg_chart_version
  namespace        = var.cnpg_namespace
  create_namespace = true

  # helm's own --wait, matching stack.sh's `helm upgrade --install ... --wait
  # --timeout 5m`: a readiness condition the tool already understands.
  wait    = true
  timeout = 300
}

resource "null_resource" "wait_for_crd" {
  # Runs even when this instance didn't install the operator (a prior
  # instance on the same cluster did): still confirms the CRD this module
  # depends on is actually Established before applying the Cluster CR below.
  depends_on = [helm_release.cnpg]

  triggers = {
    cnpg_chart_version = var.cnpg_chart_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # kubectl's own built-in CRD readiness condition, not a hand-rolled
    # poll: a near-verbatim port of stack.sh's wait_for_crd().
    command = "kubectl --kubeconfig ${var.kubeconfig} wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=180s"
  }
}

resource "local_file" "cluster_cr" {
  filename = "${path.root}/.rendered/cdc-cnpg-cluster-${var.namespace}.yaml"
  content = templatefile("${path.module}/templates/cluster.yaml.tftpl", {
    namespace                     = var.namespace
    system                        = var.system
    instances                     = var.instances
    postgres_image                = var.postgres_image
    debezium_password_secret_name = var.debezium_password_secret_name
  })
}

# The CNPG pod-absence poll spec 3.4 permits to keep. No native resource
# tracks CNPG's own graceful-shutdown pod teardown timing, so this is a
# small, explained hand-roll: it has no create provisioner, only a
# destroy-time poll for the Cluster's instance pods' absence, run AFTER
# kubectl_manifest.cluster_cr's own destroy has already deleted the Cluster
# CR (that ordering comes from kubectl_manifest.cluster_cr depending on this
# resource below, not the reverse: Terraform destroys dependents before
# their dependencies, so the CR delete that triggers CNPG's shutdown always
# runs before this poll starts watching for pods to disappear).
resource "null_resource" "pod_absence_poll" {
  depends_on = [null_resource.wait_for_crd]

  triggers = {
    namespace    = var.namespace
    cluster_name = local.cluster_name
    kubeconfig   = var.kubeconfig
    deadline     = tostring(var.teardown_pod_absence_timeout_seconds)
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    # Requires bash explicitly (not the default /bin/sh) for $SECONDS below.
    command = <<-EOT
      set -e
      deadline=$((SECONDS+${self.triggers.deadline}))
      while true; do
        if query_output="$(kubectl --request-timeout=10s --kubeconfig ${self.triggers.kubeconfig} get pods -n ${self.triggers.namespace} -l cnpg.io/cluster=${self.triggers.cluster_name} --no-headers)"; then
          [ -n "$query_output" ] || break
        else
          query_status=$?
          echo "cnpg_postgres: unable to query instance pods for ${self.triggers.cluster_name} in ${self.triggers.namespace} (kubectl exit $query_status)" >&2
          exit "$query_status"
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
          echo "cnpg_postgres: instance pods for ${self.triggers.cluster_name} still present after ${self.triggers.deadline}s, giving up" >&2
          exit 1
        fi
        sleep 5
      done
    EOT
  }
}

resource "kubectl_manifest" "cluster_cr" {
  depends_on = [null_resource.wait_for_crd, local_file.cluster_cr, null_resource.pod_absence_poll]

  yaml_body = local_file.cluster_cr.content
  force_new = false

  timeouts {
    create = "900s"
    update = "900s"
  }

  wait_for {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

resource "kubernetes_job_v1" "grant_select" {
  depends_on = [kubectl_manifest.cluster_cr]

  metadata {
    name      = "cdc-grant-select"
    namespace = var.namespace
    labels = {
      "living-stack"           = var.system
      "living-stack-component" = "orders-db"
    }
  }

  spec {
    backoff_limit = 20

    template {
      metadata {
        labels = {
          "living-stack"           = var.system
          "living-stack-component" = "orders-db"
        }
      }

      spec {
        restart_policy       = "OnFailure"
        enable_service_links = false

        container {
          name  = "grant-select"
          image = var.postgres_image
          command = ["sh", "-c", <<-EOT
            set -e
            until psql -c 'select 1' >/dev/null 2>&1; do
              echo "waiting for shop-rw to accept connections..."
              sleep 5
            done
            until psql -tAc "select 1 from pg_roles where rolname='debezium'" | grep -q 1; do
              echo "waiting for managed role debezium to be reconciled..."
              sleep 5
            done
            psql -v ON_ERROR_STOP=1 \
              -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium" \
              -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO debezium"
            echo "grants applied"
          EOT
          ]

          env {
            name  = "PGHOST"
            value = "${local.cluster_name}-rw"
          }
          env {
            name  = "PGPORT"
            value = "5432"
          }
          env {
            name  = "PGDATABASE"
            value = "shop"
          }
          env {
            name  = "PGUSER"
            value = "postgres"
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = "${local.cluster_name}-superuser"
                key  = "password"
              }
            }
          }
        }
      }
    }
  }

  # Native fit per docs/terraform-scene-layout.md section 4: the kubernetes
  # provider's own Job-completion wait, replacing stack.sh's separate
  # `kubectl wait job/cdc-grant-select --for=condition=Complete`.
  wait_for_completion = true

  timeouts {
    create = "10m"
  }
}
