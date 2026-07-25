variable "name" {
  type        = string
  description = "Prefixo usado no nome e nas tags de todos os recursos de rede (ex.: kube-news-dev)."
}

variable "cidr_block" {
  type        = string
  description = "Bloco CIDR da VPC (ex.: 10.0.0.0/16)."
}

variable "availability_zones" {
  type        = list(string)
  description = "AZs onde as subnets serão distribuídas. A ordem define o pareamento com as listas de CIDR. Mínimo de 2 AZs, exigência do control plane do EKS."
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs das subnets públicas, uma por AZ, na mesma ordem de availability_zones. Recebem o NAT Gateway e os load balancers voltados para a internet."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs das subnets privadas, uma por AZ, na mesma ordem de availability_zones. É onde os worker nodes rodam."
}

variable "single_nat_gateway" {
  type        = bool
  description = "Quando true, cria um único NAT Gateway compartilhado por todas as subnets privadas (mais barato, sem HA). Quando false, cria um NAT por AZ."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags aplicadas a todos os recursos criados pelo módulo."
  default     = {}
}
