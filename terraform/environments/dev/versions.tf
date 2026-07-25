terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
  }

  # Backend local: o state deste ambiente vive em terraform.tfstate,
  # nesta pasta. O isolamento entre ambientes continua sendo o diretório.
  backend "local" {}
}
