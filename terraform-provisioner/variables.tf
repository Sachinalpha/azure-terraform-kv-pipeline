variable "client_id" {}

variable "client_secret" {
  sensitive = true
}

variable "tenant_id" {}

variable "subscription_id" {}

variable "resource_group_name" {
  type = string
}

variable "key_vault_name" {
  type = string
}

variable "app_object_id" {
  type = string
}


