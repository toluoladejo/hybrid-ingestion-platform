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
