# --------------------------------------------
# Random number for uniqueness
# --------------------------------------------
resource "random_integer" "kv_rand" {
  min = 100
  max = 999
}

# --------------------------------------------
# Key Vault Name 
# --------------------------------------------
locals {
  segments         = split("-", var.rg_name)
  n-name           = slice(local.segments, 0, 4)
  trimmed_segments = [for s in local.n-name : substr(s, 0, 9)]
  kv_base          = join("", local.trimmed_segments)

  # Final Key Vault name
  kv_final_name = lower("${local.kv_base}${random_integer.kv_rand.result}key")

   # PEP name creation
  rg_segments = split("-", var.rg_name)
  pep_part1 = local.rg_segments[0]               
  pep_part2 = local.rg_segments[1]               
  pep_part3 = substr(local.rg_segments[2], 0, 9) 
  pep_part4 = local.rg_segments[3]               
  pep_number = random_integer.kv_rand.result  

  kv_pep_name = lower("${local.pep_part1}-${local.pep_part2}-${local.pep_part3}-${local.pep_part4}-${local.pep_number}-pep")

}

module "kvault" {
  source              = "../Modules/Key Vault"
  key_vault_name      = local.kv_final_name
  resource_group_name = var.rg_name
  tenant_id           = var.tenant_id
  vnet_name           = var.vnet_name
  vnet_rg             = var.vnet_rg
  shared_subnet_name    = var.subnet_name
  private_endpoint_name = local.kv_pep_name
}
