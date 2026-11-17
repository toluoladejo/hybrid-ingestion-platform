variable "env" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "admin_object_id" {
  type        = string
  description = "Entra object ID of the SQL admin (you): az ad signed-in-user show --query id -o tsv"
}

variable "admin_login" {
  type        = string
  default     = "watermark-sql-admin"
  description = "Display name for the Entra admin. Only a label; the object ID is what counts."
}

variable "allowed_ip" {
  type    = string
  default = ""
}
