# Infraestrutura — kube-news

Terraform para o cluster EKS que roda a aplicação kube-news.

```
terraform/
├── modules/
│   ├── network/   VPC, subnets públicas/privadas, IGW, NAT, route tables
│   └── eks/       control plane, IAM, managed node group, add-ons
└── environments/
    └── dev/       ambiente de desenvolvimento (state próprio)
```

Módulo descreve **como** a infraestrutura é construída; ambiente descreve **o que** existe
e com quais valores. Ambiente novo se cria copiando `environments/dev` e ajustando
o `terraform.tfvars`.

## O que o ambiente de dev provisiona

| Componente | Configuração |
|---|---|
| VPC | `10.0.0.0/16`, 2 AZs |
| Subnets | 2 públicas (`/20`) + 2 privadas (`/20`), taggeadas para descoberta de ELB |
| NAT Gateway | 1 compartilhado (dev; em prod, um por AZ) |
| Control plane | EKS **1.36**, `authentication_mode = API`, endpoint público + privado |
| Logs | api, audit, authenticator no CloudWatch, retenção de 7 dias |
| Worker nodes | managed node group, **2× t3.medium** on-demand, AL2023, disco 20 GiB, subnets privadas |
| Add-ons | vpc-cni, kube-proxy, coredns, eks-pod-identity-agent |

Versões consultadas no registry em 25/07/2026: AWS provider 6.56.0, Terraform CLI 1.15.8,
EKS 1.36 (última versão em standard support).

## Pré-requisitos

- Credenciais AWS com permissão para EKS, EC2, VPC, IAM e CloudWatch Logs

## State

Backend **local**: o state de cada ambiente fica em `terraform.tfstate`, dentro da própria
pasta do ambiente — ignorado pelo git, porque state carrega valores sensíveis em texto claro.

Isso implica que o state existe só na máquina de quem aplicou: não há lock, não há
compartilhamento entre pessoas, e perder a pasta significa perder o rastro dos recursos
criados (que continuam existindo e cobrando na AWS). Faça backup do `terraform.tfstate`
antes de trocar de máquina. Quando mais de uma pessoa for aplicar, troque para um backend
remoto — é mudar o bloco `backend` em `environments/dev/versions.tf` e rodar
`terraform init -migrate-state`.

## Uso

```bash
cd environments/dev

terraform init
terraform plan
terraform apply

# acesso ao cluster
aws eks update-kubeconfig --region us-east-1 --name kube-news-dev
kubectl get nodes
```

Para destruir: `terraform destroy`.

## Ajustes que provavelmente você vai querer

- **`endpoint_public_access_cidrs`** está em `0.0.0.0/0`. A autenticação continua exigida,
  mas restringir ao IP de saída do time é o certo assim que possível.
- **`single_nat_gateway = true`** (em `main.tf`) economiza em dev ao custo de ser um SPOF
  entre as AZs. Em prod, `false`.
- **IRSA** não está configurado. O output `cluster_oidc_issuer_url` é o ponto de partida
  quando um workload precisar de permissão IAM própria.
