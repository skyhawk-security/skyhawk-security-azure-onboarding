terraform {
  required_providers {
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.8.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13.1"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "3.7.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5.0"
    }
  }
  required_version = ">= 1.13.0"
}
