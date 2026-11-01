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

variable "outbox_path" {
  type        = string
  default     = "C:\\outbox"
  description = "Folder on the SHIR machine that the pipeline picks *.csv files up from."
}

variable "outbox_user" {
  type        = string
  description = "Windows account (HOSTNAME\\user) the SHIR uses to read/move files in outbox_path."
}
