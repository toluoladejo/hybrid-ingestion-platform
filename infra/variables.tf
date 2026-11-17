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

variable "synapse_location" {
  type        = string
  default     = null
  description = <<-EOT
    Region for the Synapse workspace only. Defaults to location. Set it when Azure refuses
    the workspace with SqlServerRegionDoesNotAllowProvisioning (the region has no SQL capacity
    for your subscription). The workspace can use a lake in another region; you pay a little
    cross-region egress and latency.
  EOT
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

# ---------- Watermark test (synapse/, sql/watermark/) ----------

variable "deploy_watermark_test" {
  type        = bool
  default     = false
  description = "Deploy the Azure SQL DB used by the synapse/ watermark pipeline replica."

  validation {
    condition     = !var.deploy_watermark_test || (var.deploy_spark && var.reader_object_id != "")
    error_message = "deploy_watermark_test needs deploy_spark = true (the notebooks run on sparksmall) and reader_object_id set (it becomes the SQL Entra admin)."
  }
}

variable "synapse_git_repo" {
  type = object({
    account_name    = string
    repository_name = string
    branch_name     = string
    root_folder     = optional(string, "/synapse")
  })
  default     = null
  description = "GitHub link for Synapse Studio. branch_name is the collaboration branch; Debug from any branch."
}

# true when tr_landing_csv already exists in the factory but not in the Terraform state
# (a failed apply created it and could not start it). Terraform then adopts it instead of
# trying to create it again. Harmless to leave on once it is in the state.
variable "import_landing_trigger" {
  type    = bool
  default = false
}
