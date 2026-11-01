variable "env" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "storage_account_id" { type = string }
variable "storage_dfs_endpoint" { type = string }
variable "key_vault_id" { type = string }
variable "outbox_path" { type = string } # e.g. "C:\\outbox"
variable "outbox_user" { type = string } # e.g. "LAPTOP-NAME\\adfreader"
variable "outbox_password_secret_name" {
  type        = string
  default     = "outbox-password"
  description = "Key Vault secret holding the Windows password for outbox_user. Set by hand, never by Terraform."
}
outbox_path = "C:\\outbox"
outbox_user = "VILSHUB-NET\\adfreader"   # run `hostname` in PowerShell