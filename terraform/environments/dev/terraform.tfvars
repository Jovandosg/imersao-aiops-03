region      = "us-east-1"
project     = "kube-news"
environment = "dev"

vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.0.0/20", "10.0.16.0/20"]
private_subnet_cidrs = ["10.0.32.0/20", "10.0.48.0/20"]

kubernetes_version = "1.36"

node_instance_types = ["t3.medium"]
node_desired_size   = 2
node_min_size       = 2
node_max_size       = 3

# Restrinja para o IP de saída do time antes de usar isso fora de dev.
endpoint_public_access_cidrs = ["0.0.0.0/0"]
