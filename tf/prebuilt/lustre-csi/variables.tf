variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "cluster_name" {
  description = "The name of the GKE cluster"
  type        = string
}

variable "location" {
  description = "GCP location (region or zone)"
  type        = string
  default     = "us-central1-a"
}

variable "zone" {
  description = "GCP zone for the cluster nodes and Managed Lustre instance"
  type        = string
  default     = "us-central1-a"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "machine_type" {
  type    = string
  default = "g2-standard-4"
}

variable "kubernetes_version" {
  description = "GKE control-plane/node version. Must be >= 1.33.2-gke.1111000 for the Managed Lustre CSI driver; \"1.33\" resolves to the latest 1.33 patch."
  type        = string
  default     = "1.33"
}
