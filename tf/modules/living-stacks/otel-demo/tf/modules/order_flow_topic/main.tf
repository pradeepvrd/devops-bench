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

# The order-flow KafkaTopic CR retains its original null_resource + kubectl
# identity for state compatibility with existing callers. Newer streaming
# resources use kubectl_manifest, but migrating this address would replace a
# live topic unless callers also perform an explicit state move. Applied into
# var.kafka_namespace, the shared streaming scene's
# Kafka namespace, not this stack's own workload namespace: mirrors
# stack.sh's "the KafkaTopic CR is applied into $KAFKA_NS, not $NS".

terraform {
  required_providers {
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

resource "null_resource" "wait_for_crd" {
  triggers = {
    kafka_namespace = var.kafka_namespace
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # kubectl's own built-in CRD readiness condition: this scene depends on
    # the streaming scene's Kafka already being up (environments.yaml:
    # shop depends_on stream), so the CRD is expected to already be
    # Established; this just confirms it rather than assuming it.
    command = "kubectl --kubeconfig ${var.kubeconfig} wait --for=condition=Established crd/kafkatopics.kafka.strimzi.io --timeout=180s"
  }
}

resource "local_file" "topic_cr" {
  filename = "${path.root}/.rendered/otel-demo-kafka-topic-${var.resource_name}.yaml"
  content = templatefile("${path.module}/templates/kafka-topics.yaml.tftpl", {
    kafka_namespace = var.kafka_namespace
    namespace       = var.namespace
    resource_name   = var.resource_name
    system          = var.system
    kafka_topic     = var.topic_name
    partitions      = var.partitions
    retention_ms    = var.retention_ms
  })
}

resource "null_resource" "apply_topic" {
  depends_on = [null_resource.wait_for_crd, local_file.topic_cr]

  triggers = {
    kafka_namespace = var.kafka_namespace
    resource_name   = var.resource_name
    manifest_path   = local_file.topic_cr.filename
    content_hash    = local_file.topic_cr.content_md5
    kubeconfig      = var.kubeconfig
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # kubectl wait --for=condition=Ready is Strimzi's own published Ready
    # condition on the KafkaTopic CR, a near-verbatim port of stack.sh's
    # up_gke applying manifests/kafka-topics.yaml before installing the
    # chart.
    command = "kubectl --kubeconfig ${var.kubeconfig} apply -f ${local_file.topic_cr.filename} && kubectl --kubeconfig ${var.kubeconfig} wait kafkatopic/${var.resource_name} -n ${var.kafka_namespace} --for=condition=Ready --timeout=${var.topic_ready_timeout}"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "kubectl --kubeconfig ${self.triggers.kubeconfig} delete -f ${self.triggers.manifest_path} --ignore-not-found --wait --timeout=120s"
  }
}
