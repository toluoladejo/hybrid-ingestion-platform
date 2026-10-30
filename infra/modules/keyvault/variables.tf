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
