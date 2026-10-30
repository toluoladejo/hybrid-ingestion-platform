variable "env" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "suffix" {
  type        = string
  description = "Stable suffix that makes the name globally unique."
}

variable "workspace_id" {
  type = string
}

variable "containers" {
  type    = list(string)
  default = ["landing", "raw", "curated", "quarantine", "archive"]
}
