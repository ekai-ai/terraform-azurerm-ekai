plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.33.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

# Flags the Key Vault and the Postgres server/database for missing
# prevent_destroy. self-deploy-destroy.sh has to be able to tear a whole
# install down, and prevent_destroy can't be made conditional, so these
# resources can't carry it.
rule "azurerm_resources_missing_prevent_destroy" {
  enabled = false
}
