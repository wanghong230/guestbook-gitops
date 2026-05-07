variable "stage" {
  description = "Kargo stage that triggered this apply (dev | staging | prod)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.stage)
    error_message = "stage must be one of: dev, staging, prod."
  }
}

variable "image_tag" {
  description = "Container image tag being promoted, sourced from Kargo Freight."
  type        = string
  default     = "unset"
}
