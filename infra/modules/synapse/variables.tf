variable "env" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "storage_account_id" { type = string }

variable "storage_filesystem_id" {
  type        = string
  description = "DFS URL of the workspace's primary container, e.g. https://<account>.dfs.core.windows.net/synapse"
}

variable "github_owner" {
  type        = string
  default     = ""
  description = "GitHub user or org. Set it (dev only) to link Synapse Studio to this repo."
}

variable "github_repo" {
  type    = string
  default = "hybrid-ingestion-platform"
}

variable "collaboration_branch" {
  type        = string
  default     = "main"
  description = "Branch Synapse Studio publishes from."
}

variable "allowed_ip" {
  type        = string
  default     = ""
  description = "Your public IP, for Studio and SQL clients (curl -s https://api.ipify.org)."
}

variable "reader_object_id" {
  type        = string
  default     = ""
  description = "Your Entra object ID: lake read access for serverless exploration."
}

variable "deploy_spark" {
  type    = bool
  default = false
}
