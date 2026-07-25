locals {
  name = "${var.project}-${var.environment}"
}

# Duas primeiras AZs da região que suportam instâncias sob demanda —
# o control plane do EKS exige subnets em pelo menos 2 AZs.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "network" {
  source = "../../modules/network"

  name                 = local.name
  cidr_block           = var.vpc_cidr
  availability_zones   = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  # Dev: um NAT só. Em prod use um por AZ.
  single_nat_gateway = true

  tags = {
    Name = local.name
  }
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name
  kubernetes_version = var.kubernetes_version

  # Nodes em subnet privada, saindo pela internet via NAT.
  subnet_ids = module.network.private_subnet_ids

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  node_instance_types = var.node_instance_types
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
}
