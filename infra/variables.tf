variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "env must be dev or prod."
  }
}

variable "location" {
  type        = string
  default     = null
  description = "Defaults to the resource group's location."
}

variable "tags" {
  type    = map(string)
  default = {}
}
