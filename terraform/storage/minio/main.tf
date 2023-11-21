terraform {
  cloud {
    hostname     = "app.terraform.io"
    organization = "onedr0p"
    workspaces {
      name = "arpa-home-storage"
    }
  }
  required_providers {
    sops = {
      source  = "carlpett/sops"
      version = "1.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.9.1"
    }
    minio = {
      source  = "aminueza/minio"
      version = "~> 2.0"  # Replace with your desired version constraint
    }
  }
  required_version = ">= 1.3.0"
}

data "sops_file" "secrets" {
  source_file = "./secrets.sops.yaml"
}
