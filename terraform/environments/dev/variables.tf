variable "region" {
  type        = string
  description = "Região AWS onde o ambiente é provisionado."
}

variable "project" {
  type        = string
  description = "Nome do projeto, usado como prefixo de nomes e nas tags padrão."
}

variable "environment" {
  type        = string
  description = "Identificador do ambiente (dev)."
}

variable "vpc_cidr" {
  type        = string
  description = "Bloco CIDR da VPC do ambiente."
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs das subnets públicas, uma por AZ."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs das subnets privadas, uma por AZ."
}

variable "kubernetes_version" {
  type        = string
  description = "Versão do Kubernetes do cluster EKS."
}

variable "node_instance_types" {
  type        = list(string)
  description = "Tipos de instância dos worker nodes."
}

variable "node_desired_size" {
  type        = number
  description = "Quantidade desejada de worker nodes."
}

variable "node_min_size" {
  type        = number
  description = "Mínimo de worker nodes."
}

variable "node_max_size" {
  type        = number
  description = "Máximo de worker nodes."
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  description = "CIDRs autorizados a acessar o endpoint público da API do cluster."
}
