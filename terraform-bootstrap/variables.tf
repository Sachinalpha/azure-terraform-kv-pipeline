variable "resource_group_name" {
  type    = string
  default = "poc21-rg321"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "client_id" {
  type = string
}

variable "client_secret" {
  type = string
  sensitive = true
}

variable "tenant_id" {
  type = string
}

variable "subscription_id" {
  type = string
}
