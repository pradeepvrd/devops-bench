variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "cluster_name" {
  description = "The name of the GKE cluster (run-token-prefixed by the harness under parallel runs)"
  type        = string
}

variable "location" {
  description = "GCP zone or region for the cluster"
  type        = string
  default     = "us-central1-a"
}

variable "node_count" {
  type    = number
  default = 3
}

variable "machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "namespace" {
  description = "Namespace the workloads are deployed into. 'default' always exists; any other value must be pre-created."
  type        = string
  default     = "default"
}

variable "seed_mode" {
  description = <<-EOT
    Controls which workloads this stack pre-seeds on top of the shared infra
    (cluster + KSA hypercomputer-d1-vllm-sa + Workload Identity + GCS bucket):
      - "full"            : deploy the complete app (frontend, vllm-server, vllm-service, HPA)
                            with USE_GEMINI_API=false. Used by get-app-architecture so the
                            topology is fully discoverable.
      - "infra-only"      : provision ONLY the shared infra. Used by deploy-config; the agent
                            is the one that applies the vllm workloads.
      - "broken-frontend" : provision shared infra + deploy the frontend in a BROKEN state
                            (USE_GEMINI_API=true). Used by fix-config; the agent's job is to
                            re-apply the corrected manifest.
  EOT
  type        = string
  default     = "full"

  validation {
    condition     = contains(["full", "infra-only", "broken-frontend"], var.seed_mode)
    error_message = "seed_mode must be one of: full, infra-only, broken-frontend."
  }
}
