output "vpc_id" {
  description = "ID da VPC criada."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Bloco CIDR da VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas, na ordem das AZs informadas."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas, na ordem das AZs informadas. É o que se passa para os worker nodes do EKS."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_public_ips" {
  description = "IPs públicos dos NAT Gateways, úteis para liberar a saída do cluster em allowlists de terceiros."
  value       = aws_eip.nat[*].public_ip
}
