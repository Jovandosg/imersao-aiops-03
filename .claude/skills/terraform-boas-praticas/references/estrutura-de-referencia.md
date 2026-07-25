# Estrutura de referência

Um projeto completo e coerente para copiar em vez de reinventar. Os providers e recursos aqui são
genéricos de propósito (`exemplo_*`) — troque pelos reais da cloud em uso; o que importa é o **formato**:
o que vai em cada arquivo, o que o módulo expõe, e como os ambientes divergem.

**Índice**
- [Árvore de diretórios](#árvore-de-diretórios)
- [Um módulo completo](#um-módulo-completo-modulesnetwork)
- [Um ambiente completo](#um-ambiente-completo-environmentsdev)
- [Como prod diverge de dev](#como-prod-diverge-de-dev)
- [Antipadrões](#antipadrões)
- [Fluxo de trabalho](#fluxo-de-trabalho)

---

## Árvore de diretórios

```
terraform/
├── modules/
│   ├── network/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   └── app-runtime/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── versions.tf
└── environments/
    ├── dev/
    │   ├── main.tf              # só chamadas de módulo
    │   ├── variables.tf
    │   ├── terraform.tfvars     # os valores DESTE ambiente
    │   ├── providers.tf         # configuração do provider + backend
    │   ├── versions.tf          # required_version + required_providers
    │   ├── outputs.tf           # opcional: o que este ambiente expõe
    │   └── .terraform.lock.hcl  # versionado no git
    ├── stg/                     # mesma estrutura
    └── prod/                    # mesma estrutura
```

Módulo sem `providers.tf` e sem `terraform.tfvars` não é esquecimento — é a regra: módulo não configura
provider e não carrega valor de ambiente.

---

## Um módulo completo (`modules/network`)

### `versions.tf`

Declara de que precisa. Sem `required_version` (quem decide a versão do CLI é o root) e **sem bloco
`provider`** — a configuração desce por herança de quem chama.

```hcl
terraform {
  required_providers {
    exemplo = {
      source  = "hashicorp/exemplo"
      version = "~> 9.4" # versão consultada no registry, não escrita de memória
    }
  }
}
```

### `variables.tf`

Toda variável com `type` e `description`. Sem `default` no que muda por natureza entre ambientes — isso
força a diferença a aparecer no `terraform.tfvars`, onde é legível.

```hcl
variable "nome" {
  type        = string
  description = "Prefixo de nomeação dos recursos desta rede. Ex.: kube-news-dev."
}

variable "cidr" {
  type        = string
  description = "Bloco CIDR da rede. Não pode se sobrepor a outros ambientes."
}

variable "zonas" {
  type        = list(string)
  description = "Zonas de disponibilidade em que criar subnets. Uma subnet pública e uma privada por zona."

  validation {
    condition     = length(var.zonas) > 0
    error_message = "Informe ao menos uma zona."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags aplicadas a todos os recursos criados por este módulo."
  default     = {}
}
```

### `main.tf`

Os recursos da capacidade. Nenhum valor que varia por ambiente fica fixo aqui.

```hcl
resource "exemplo_network" "this" {
  name = var.nome
  cidr = var.cidr
  tags = var.tags
}

resource "exemplo_subnet" "publica" {
  for_each = toset(var.zonas)

  network_id = exemplo_network.this.id
  zone       = each.value
  cidr       = cidrsubnet(var.cidr, 4, index(var.zonas, each.value))
  public     = true
  tags       = merge(var.tags, { Name = "${var.nome}-publica-${each.value}" })
}

resource "exemplo_subnet" "privada" {
  for_each = toset(var.zonas)

  network_id = exemplo_network.this.id
  zone       = each.value
  cidr       = cidrsubnet(var.cidr, 4, index(var.zonas, each.value) + length(var.zonas))
  public     = false
  tags       = merge(var.tags, { Name = "${var.nome}-privada-${each.value}" })
}
```

### `outputs.tf`

Só o que o consumidor precisa para conectar as coisas. Cada output é contrato público do módulo.

```hcl
output "network_id" {
  description = "ID da rede criada."
  value       = exemplo_network.this.id
}

output "subnets_privadas" {
  description = "IDs das subnets privadas, para uso por workloads sem exposição externa."
  value       = [for s in exemplo_subnet.privada : s.id]
}

output "subnets_publicas" {
  description = "IDs das subnets públicas, para uso por balanceadores."
  value       = [for s in exemplo_subnet.publica : s.id]
}
```

---

## Um ambiente completo (`environments/dev`)

### `versions.tf`

```hcl
terraform {
  required_version = ">= 1.15"

  required_providers {
    exemplo = {
      source  = "hashicorp/exemplo"
      version = "~> 9.4" # consultada no registry
    }
  }
}
```

### `providers.tf`

Backend e configuração do provider — as duas coisas que são **deste ambiente** e de mais nenhum. Repare
que a chave do state é exclusiva de `dev`.

```hcl
terraform {
  backend "exemplo" {
    bucket = "tfstate-kube-news"
    key    = "dev/terraform.tfstate" # ← exclusivo deste ambiente
    region = "us-east-1"
    lock   = true
  }
}

provider "exemplo" {
  region = var.regiao

  default_tags {
    tags = local.tags
  }
}
```

### `main.tf`

Só chamadas de módulo, ligadas pelos outputs. Nenhum `resource` aqui.

```hcl
locals {
  nome = "kube-news-${var.ambiente}"

  tags = {
    Project     = "kube-news"
    Environment = var.ambiente
    ManagedBy   = "terraform"
  }
}

module "network" {
  source = "../../modules/network"

  nome  = local.nome
  cidr  = var.cidr
  zonas = var.zonas
  tags  = local.tags
}

module "app" {
  source = "../../modules/app-runtime"

  nome        = local.nome
  subnet_ids  = module.network.subnets_privadas
  imagem      = var.imagem
  replicas    = var.replicas
  tamanho     = var.tamanho
  tags        = local.tags
}
```

### `variables.tf`

```hcl
variable "ambiente" {
  type        = string
  description = "Nome deste ambiente. Usado em nomeação e tags."
}

variable "regiao" {
  type        = string
  description = "Região em que provisionar."
}

variable "cidr" {
  type        = string
  description = "CIDR da rede deste ambiente."
}

variable "zonas" {
  type        = list(string)
  description = "Zonas de disponibilidade a usar."
}

variable "imagem" {
  type        = string
  description = "Imagem de container da aplicação, com tag."
}

variable "replicas" {
  type        = number
  description = "Número de réplicas da aplicação."
}

variable "tamanho" {
  type        = string
  description = "Perfil de recursos da instância/tarefa."
}
```

### `terraform.tfvars`

O arquivo que responde "o que é diferente neste ambiente?" — e é a única coisa que precisa ser lida
para responder.

```hcl
ambiente = "dev"
regiao   = "us-east-1"
cidr     = "10.10.0.0/16"
zonas    = ["us-east-1a"]
imagem   = "kube-news:dev"
replicas = 1
tamanho  = "small"
```

---

## Como prod diverge de dev

`environments/prod/main.tf` é praticamente idêntico ao de `dev` — **e isso é o desenho, não um
descuido.** A divergência mora nos valores:

```hcl
# environments/prod/terraform.tfvars
ambiente = "prod"
regiao   = "us-east-1"
cidr     = "10.30.0.0/16"
zonas    = ["us-east-1a", "us-east-1b", "us-east-1c"]
imagem   = "kube-news:1.4.2"
replicas = 3
tamanho  = "large"
```

```hcl
# environments/prod/providers.tf — state separado, credencial separada
terraform {
  backend "exemplo" {
    bucket = "tfstate-kube-news"
    key    = "prod/terraform.tfstate" # ← chave diferente de dev
    region = "us-east-1"
    lock   = true
  }
}
```

Responder "o que é diferente em prod?" custa um `diff environments/dev/terraform.tfvars
environments/prod/terraform.tfvars`. Com workspace, custa ler o projeto inteiro atrás de condicionais.

Quando prod tem um recurso que dev não tem (um WAF, uma réplica de leitura, um backup cross-region),
isso vira **uma chamada de módulo a mais no `prod/main.tf`** — não um `count` condicional em código
compartilhado. O ambiente que não precisa simplesmente não chama.

---

## Antipadrões

### Ambiente por workspace vs. por pasta

```hcl
# ✗ Errado
resource "exemplo_instance" "app" {
  count = terraform.workspace == "prod" ? 3 : 1
  size  = terraform.workspace == "prod" ? "large" : "small"
}
```
Todos os ambientes compartilham este código. A diferença entre eles está espalhada em condicionais, o
apply de prod carrega qualquer mudança feita "para dev", e um `workspace select` errado é invisível.

```hcl
# ✓ Certo — módulo genérico, valores no tfvars de cada pasta
module "app" {
  source   = "../../modules/app-runtime"
  replicas = var.replicas
  tamanho  = var.tamanho
}
```

### Módulo de comunidade vs. módulo próprio

```hcl
# ✗ Errado
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.13.0"
}
```
Código de terceiro no caminho crítico do provisionamento, com uma superfície de configuração que
ninguém do time domina inteira e breaking changes no prazo de outra pessoa.

```hcl
# ✓ Certo — módulo próprio, cobrindo só o que o projeto usa
module "network" {
  source = "../../modules/network"
}
```

### `provider` dentro do módulo vs. herdado

```hcl
# ✗ Errado — modules/network/main.tf
provider "exemplo" {
  region = "us-east-1"
}
```
O módulo passa a carregar *onde* provisionar: não dá para usá-lo em duas regiões ou duas contas, e
removê-lo do state deixa de ser limpo.

```hcl
# ✓ Certo — modules/network/versions.tf declara a necessidade
terraform {
  required_providers {
    exemplo = { source = "hashicorp/exemplo", version = "~> 9.4" }
  }
}
# ...e environments/dev/providers.tf configura, herdando para os módulos
```

Para múltiplas instâncias do provider (duas regiões), o módulo declara aliases e recebe explicitamente:

```hcl
# modules/backup/versions.tf
terraform {
  required_providers {
    exemplo = {
      source                = "hashicorp/exemplo"
      version               = "~> 9.4"
      configuration_aliases = [exemplo.primaria, exemplo.secundaria]
    }
  }
}

# environments/prod/main.tf
module "backup" {
  source    = "../../modules/backup"
  providers = {
    exemplo.primaria   = exemplo
    exemplo.secundaria = exemplo.dr
  }
}
```

### Versão de memória vs. consultada

```hcl
# ✗ Errado — número que "parece certo"
version = "~> 5.0"

# ✗ Errado — sem required_providers: o Terraform resolve sozinho,
#   e o resultado muda conforme o dia do init
```

```hcl
# ✓ Certo — consultar, depois escrever
# curl -s https://registry.terraform.io/v1/providers/hashicorp/exemplo \
#   | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])"
version = "~> 9.4"
```

### `resource` no root do ambiente

```hcl
# ✗ Errado — environments/dev/main.tf
resource "exemplo_bucket" "uploads" {
  name = "kube-news-dev-uploads"
}
```
Só existe em dev; quando prod precisar, alguém copia e as duas cópias divergem em silêncio.

```hcl
# ✓ Certo — vira módulo, ainda que pequeno, e cada ambiente chama com seus valores
module "storage" {
  source = "../../modules/storage"
  nome   = local.nome
  tags   = local.tags
}
```

---

## Fluxo de trabalho

Ao criar a estrutura do zero:

1. Consultar a versão do provider e do CLI no registry (comandos no `SKILL.md`, regra 4).
2. Identificar as **capacidades** do projeto — rede, banco, runtime da aplicação, storage. Cada uma é um módulo.
3. Escrever os módulos primeiro, com a interface (`variables.tf` / `outputs.tf`) antes do `main.tf` — desenhar a interface primeiro é o que evita módulo que espelha recurso.
4. Escrever `environments/dev/` inteiro e validar.
5. Copiar para os demais ambientes, ajustando `backend` (chave própria) e `terraform.tfvars`.
6. `terraform fmt -recursive` e `terraform validate` em cada pasta de ambiente.
7. Versionar os `.terraform.lock.hcl` gerados.

Ao revisar Terraform existente, varra nesta ordem — é a ordem do custo de correção, do mais barato para
o mais caro: `grep -rn "terraform.workspace"` → `grep -rn 'source *= *"[^./]'` (sources externos) →
`grep -rn "^provider" modules/` → `resource` no root dos ambientes → versões defasadas em
`required_providers`.
