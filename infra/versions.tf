terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Remote state in the storage account created by scripts/bootstrap.sh.
  # storage_account_name and key are passed at init time:
  #   terraform init -backend-config="storage_account_name=<name>" -backend-config="key=dev.tfstate"
  backend "azurerm" {
    resource_group_name = "rg-ingest-tfstate"
    container_name      = "tfstate"
    use_azuread_auth    = true
  }
}

# Credentials come from the environment: `az login` locally, or ARM_USE_OIDC +
# ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID in GitHub Actions.
provider "azurerm" {
  features {
    key_vault {
      # The pipeline identity is Contributor on the resource group only; it cannot purge.
      purge_soft_delete_on_destroy = false
    }
  }

  # Same reason: registering resource providers needs subscription-level rights.
  resource_provider_registrations = "none"
}
