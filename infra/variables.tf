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

# ---------- Synapse (week 5) ----------

variable "github_owner" {
  type        = string
  default     = ""
  description = "GitHub owner of this repo. Set in dev.tfvars to link Synapse Studio to Git; leave empty in prod."
}

variable "allowed_ip" {
  type        = string
  default     = ""
  description = "Your public IP for Synapse Studio and SQL clients."
}

variable "reader_object_id" {
  type        = string
  default     = ""
  description = "Your Entra object ID (az ad signed-in-user show --query id -o tsv)."
}

variable "deploy_spark" {
  type    = bool
  default = false
}
