terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.location
}

provider "google-beta" {
  project = var.project_id
  region  = var.location
}

resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes-lus-${trim(substr(var.cluster_name, 0, 10), "-")}"
  display_name = "GKE Node Service Account for Lustre CSI ${var.cluster_name}"
}

resource "google_project_iam_member" "gke_nodes_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_metadata_writer" {
  project = var.project_id
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_compute_network" "custom" {
  provider                = google-beta
  name                    = "lus-net-${var.cluster_name}"
  auto_create_subnetworks = true
}

# Sweep GKE-managed firewall rules off the auto-mode VPC at teardown. GKE deletes
# these asynchronously after the cluster is gone, so they linger and block
# `google_compute_network.custom` from being destroyed (leaking the VPC). The
# dependency chain (cluster -> this -> network) orders the destroy so this runs
# AFTER the cluster is destroyed and BEFORE the network is.
resource "null_resource" "firewall_cleanup" {
  triggers = {
    project = var.project_id
    network = google_compute_network.custom.name
  }

  depends_on = [google_compute_network.custom]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -e
      rules=$(gcloud compute firewall-rules list \
        --project='${self.triggers.project}' \
        --filter="network~${self.triggers.network}" \
        --format='value(name)' 2>/dev/null || true)
      if [ -n "$rules" ]; then
        echo "$rules" | xargs -r -n1 gcloud compute firewall-rules delete \
          --project='${self.triggers.project}' --quiet || true
      fi
    EOT
  }
}

resource "google_compute_global_address" "private_ip_alloc" {
  provider      = google-beta
  name          = "lus-ip-${var.cluster_name}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.custom.id
}

resource "google_service_networking_connection" "default" {
  provider                = google-beta
  network                 = google_compute_network.custom.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
}

resource "google_container_cluster" "primary" {
  provider                 = google-beta
  name                     = var.cluster_name
  location                 = var.location
  network                  = google_compute_network.custom.id
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  # Managed Lustre CSI driver requires GKE >= 1.33.2-gke.1111000.
  min_master_version = var.kubernetes_version

  ip_allocation_policy {}

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    lustre_csi_driver_config {
      enabled = true
      # Required when mounting an EXISTING instance created with
      # gke_support_enabled, regardless of cluster version (port 6988).
      enable_legacy_lustre_port = true
    }
  }

  depends_on = [
    google_service_networking_connection.default,
    null_resource.firewall_cleanup,
  ]
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "gpu-node-pool"
  location   = var.location
  cluster    = google_container_cluster.primary.name
  node_count = var.node_count
  version    = var.kubernetes_version

  node_config {
    preemptible     = false
    machine_type    = var.machine_type
    service_account = google_service_account.gke_nodes.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    guest_accelerator {
      type  = "nvidia-l4"
      count = 1

      gpu_driver_installation_config {
        gpu_driver_version = "DEFAULT"
      }
    }
  }
}

resource "google_lustre_instance" "instance" {
  provider                    = google-beta
  instance_id                 = "lustre-${var.cluster_name}"
  location                    = var.zone
  filesystem                  = "lustrefs"
  capacity_gib                = 18000
  per_unit_storage_throughput = 1000
  network                     = google_compute_network.custom.id
  gke_support_enabled         = true

  depends_on = [
    google_service_networking_connection.default
  ]

  timeouts {
    create = "120m"
    delete = "60m"
  }
}

output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_location" {
  value = google_container_cluster.primary.location
}
