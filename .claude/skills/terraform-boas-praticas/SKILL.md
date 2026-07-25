---
name: terraform-boas-praticas
description: >
  Escreve e organiza Terraform seguindo quatro regras estruturais inegociáveis: tudo em módulos próprios
  pensados para reaproveitamento, ambientes separados em pastas (nunca em workspace), zero módulos de
  comunidade, e versão de provider sempre consultada no registry antes de ser escrita. Use sempre que o
  usuário disser "escreve o terraform", "cria a infra como código", "provisiona isso com terraform",
  "monta a estrutura do projeto terraform", "organiza esse terraform", "revisa meu terraform", "cria o
  módulo", "adiciona um ambiente novo", ou apontar um repositório com arquivos .tf querendo criar ou
  mudar infraestrutura. Ative também quando for apenas criar ou editar um único arquivo .tf — a estrutura
  errada nasce justamente do "só um main.tf rapidinho" — e quando o pedido mencionar um módulo de
  comunidade (terraform-aws-modules, Azure/, terraform-google-modules), porque nesse caso o certo é
  escrever o módulo próprio equivalente. Vale para qualquer cloud ou provider. NÃO acione para:
  manifestos Kubernetes/Helm puros (sem Terraform envolvido), Pulumi, CloudFormation ou CDK, e debug de
  erro de API da cloud (permissão, quota, limite do serviço) que não é questão de estrutura de código.
---

# Terraform — Boas Práticas

Terraform ruim quase nunca é sintaxe errada. É estrutura errada: um `main.tf` que cresceu, ambientes que divergem por condicional escondido, um módulo de terceiro no caminho crítico do provisionamento, e uma versão de provider que alguém escreveu de memória há dois anos. Nada disso quebra no `plan` — quebra seis meses depois, quando mudar dev sem mexer em prod deixou de ser possível.

As quatro regras abaixo existem para tornar esses erros difíceis de cometer. Elas valem para qualquer cloud e qualquer provider.

## As quatro regras

| Regra | O que isso descarta na prática |
|---|---|
| **1. Tudo em módulos, pensados para reuso** | `resource` solto no root, `main.tf` monolítico, copiar e colar bloco de recurso entre projetos |
| **2. Ambientes em pastas, nunca em workspace** | `terraform workspace new/select`, `count = terraform.workspace == "prod" ? 1 : 0`, um state para todos os ambientes |
| **3. Nunca módulos de comunidade** | `source = "terraform-aws-modules/vpc/aws"` e qualquer `source` que aponte para fora do repositório ou da organização |
| **4. Versão do provider sempre consultada** | escrever `version = "~> 5.0"` de memória, omitir `required_providers`, deixar o Terraform resolver sozinho |

Quando o pedido do usuário conflitar com uma delas (por exemplo: "usa o módulo de VPC da comunidade" ou "separa os ambientes com workspace"), não execute em silêncio nem recuse: diga em uma frase o que a regra manda e por quê, entregue seguindo a regra, e deixe claro o que foi feito diferente do pedido. Se o usuário reafirmar, é decisão dele — siga.

## Quando aprofundar

| Situação | Onde ir |
|---|---|
| Vai criar a estrutura do zero, ou precisa de um exemplo completo de módulo e de ambiente para copiar | `references/estrutura-de-referencia.md` |
| Está revisando Terraform existente e quer o mapa de antipadrão → correção | `references/estrutura-de-referencia.md`, seção **Antipadrões** |

---

## Estrutura canônica

```
terraform/
├── modules/
│   ├── network/          { main.tf, variables.tf, outputs.tf, versions.tf }
│   └── app-runtime/      { main.tf, variables.tf, outputs.tf, versions.tf }
└── environments/
    ├── dev/              { main.tf, variables.tf, versions.tf, providers.tf, terraform.tfvars }
    ├── stg/              { idem }
    └── prod/             { idem }
```

A divisão de responsabilidade é o que faz essa árvore funcionar:

- **Módulo descreve _como_** um pedaço de infraestrutura é construído. Não sabe em que ambiente está rodando.
- **Ambiente descreve _o que_ existe** e com quais valores. É uma lista de chamadas de módulo com inputs diferentes.

Disso sai um teste rápido e objetivo: **se apareceu um `resource` no root de um ambiente, algo está no lugar errado.** Ou aquilo vira módulo, ou é sinal de que o módulo certo ainda não existe. A exceção razoável é um `data` source lendo algo que já existe fora do Terraform (uma zona DNS, uma conta, uma imagem) para passar como input — isso é leitura, não criação.

---

## Regra 1 — Tudo em módulos, pensados para reuso

### O que vira módulo

Uma **capacidade**, não um recurso. "Rede", "banco de dados", "runtime da aplicação" são módulos. "Uma subnet" não é — subnet é detalhe interno do módulo de rede.

O critério é: isto vai ser instanciado mais de uma vez, seja entre ambientes (dev/stg/prod), seja entre projetos? Se sim, é módulo. Como os ambientes são pastas separadas (regra 2), praticamente toda infraestrutura de aplicação se qualifica — cada ambiente é um consumidor.

O contrapeso importa tanto quanto a regra: **um módulo com um único consumidor e nenhuma variação não é reuso, é indireção.** Ele adiciona um salto de arquivo sem entregar nada. Se você está criando um módulo que só envolve um recurso e é chamado uma vez, a granularidade está fina demais — suba um nível e agrupe pela capacidade.

### Como desenhar a interface

O que faz um módulo ser reaproveitável é a interface, não o conteúdo. Um módulo com dez recursos e três inputs bem escolhidos se reusa; um com dois recursos e vinte inputs que espelham cada atributo não se reusa, porque quem chama precisa saber tudo o que ele faz por dentro.

- **`variables.tf`** — toda variável com `type` e `description`. `description` não é burocracia: é o que o consumidor lê para saber o que passar sem abrir o `main.tf`. Use `default` só onde existe um valor sensato universal; o que muda entre ambientes por natureza (tamanho, contagem, CIDR) deve ser obrigatório, para que a diferença fique explícita no `terraform.tfvars` de cada ambiente.
- **`outputs.tf`** — exponha o que o consumidor precisa para conectar as coisas (IDs, endpoints, nomes), não tudo o que o módulo criou. Cada output é contrato: uma vez que alguém depende dele, remover quebra.
- **Nada de valor hardcoded que varia por ambiente.** Nome, tamanho, região e contagem vêm por variável. Se um valor está fixo no módulo, você acabou de decidir que ele é igual em prod e em dev.

### Provider dentro do módulo

Esta é a regra estrutural que mais quebra reuso e é a mais fácil de errar:

- **O módulo declara `required_providers`** (em `versions.tf`) — dizendo de quais providers ele precisa e em que versão.
- **O módulo nunca declara um bloco `provider`** — a configuração (região, credencial, alias) vive no root do ambiente e é herdada.

Se o módulo configurar o próprio provider, ele passa a carregar a decisão de _onde_ provisionar, e o mesmo módulo não pode mais ser usado em duas regiões ou duas contas. Pior: módulo com `provider` próprio não pode ser removido do state de forma limpa. Quando o módulo precisa de mais de uma instância do provider (duas regiões, por exemplo), declare `configuration_aliases` no `required_providers` e receba os providers via `providers = {}` na chamada.

---

## Regra 2 — Ambientes em pastas, nunca em workspace

Cada ambiente é uma pasta com seu próprio root module, seu próprio backend/state, seu próprio `terraform.tfvars` e seu próprio `.terraform.lock.hcl`.

### Por que não workspace

Workspace troca o state, mas **todos os workspaces compartilham exatamente o mesmo código**. Isso tem três consequências que só aparecem quando já é tarde:

1. **A diferença entre dev e prod deixa de ser legível.** Ela para de morar em arquivos separados e passa a morar em condicionais espalhados — `count = terraform.workspace == "prod" ? 3 : 1`, `local.tamanho[terraform.workspace]`. Ninguém consegue responder "o que exatamente é diferente em prod?" sem ler o projeto inteiro.
2. **Não existe blast radius.** Uma mudança de código destinada a dev é aplicada por cima do código de prod no próximo apply de prod. Não há como mexer em um ambiente sem tocar no arquivo do outro.
3. **`terraform apply` no workspace errado é indistinguível do certo** até o output aparecer. O ambiente é estado invisível do CLI, não algo visível no diretório em que você está.

Pasta por ambiente resolve os três de uma vez: a diferença fica legível (é o diff entre dois `terraform.tfvars`), o isolamento é físico, e o ambiente é o diretório em que você está — impossível de confundir.

### O que isso implica

- Cada pasta de ambiente tem seu próprio bloco `backend` apontando para um state separado. Nunca compartilhe chave de state entre ambientes.
- `terraform workspace new` / `select` não é usado. Se encontrar workspace em projeto existente, aponte e proponha a migração para pastas.
- **Duplicação de chamada de módulo entre ambientes é esperada e correta.** Ver o mesmo `module "network" { ... }` em `dev/main.tf` e em `prod/main.tf` com valores diferentes não é code smell — é o preço do isolamento, e é barato porque a lógica de verdade está no módulo, não ali. Não tente resolver essa duplicação com um módulo "environment" genérico envolvendo tudo: isso reintroduz o acoplamento que a separação em pastas existe para eliminar.
- Ambiente novo se cria copiando a pasta do ambiente mais próximo e ajustando `backend` + `terraform.tfvars`.

---

## Regra 3 — Nunca módulos de comunidade

Todo `source` aponta para dentro do repositório (`../../modules/network`) ou para um repositório da própria organização (`git::ssh://...`). Nada do registry público.

Isso inclui explicitamente os mais populares — `terraform-aws-modules/*`, `Azure/*`, `terraform-google-modules/*`, `cloudposse/*`. Se o pedido do usuário mencionar um deles, **escreva o módulo próprio equivalente**, cobrindo apenas o que o projeto realmente usa.

Ler o código de um módulo de comunidade como referência é legítimo e frequentemente útil — eles codificam detalhes de API que valem a pena conhecer. O que não se faz é referenciá-lo como dependência.

**Por quê:** um módulo de comunidade coloca no caminho crítico do seu provisionamento um código versionado por terceiros, com uma superfície de configuração que ninguém do time entende inteira (dezenas de inputs, a maioria irrelevante para o seu caso), e cujos breaking changes chegam no prazo de outra pessoa. O módulo próprio faz só o que o projeto precisa, cabe na cabeça de quem mantém, e muda quando o time decide.

Quando o módulo próprio for grande demais para escrever de uma vez, implemente o subconjunto que o projeto usa hoje e diga o que ficou de fora. Cobertura parcial explícita é melhor que dependência externa.

---

## Regra 4 — Versão do provider sempre consultada

**Nunca escreva uma versão de provider de memória.** Versões de provider mudam toda semana, e o que você "lembra" quase certamente já está desatualizado em vários majors. Consulte antes de escrever o `required_providers`:

```bash
# Última versão de qualquer provider do registry (funciona para qualquer namespace)
curl -s https://registry.terraform.io/v1/providers/<NAMESPACE>/<NOME> \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])"

# Exemplos: hashicorp/aws, hashicorp/azurerm, hashicorp/google,
#           hashicorp/kubernetes, hashicorp/helm, integrations/github

# Última versão do Terraform CLI, para o required_version
curl -s https://api.releases.hashicorp.com/v1/releases/terraform/latest \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])"
```

Se não houver acesso à rede, diga isso ao usuário em vez de inventar um número — uma versão chutada parece verificada e é pior que uma lacuna assumida.

### Como fixar

Com a versão em mãos, fixe com `~>` no major.minor retornado, permitindo patches:

```hcl
terraform {
  required_version = ">= 1.15"

  required_providers {
    exemplo = {
      source  = "hashicorp/exemplo"
      version = "~> 9.4"   # ← 9.4.2 veio da consulta ao registry, agora
    }
  }
}
```

- **`versions.tf` no root de cada ambiente** carrega `required_version` + `required_providers`.
- **`versions.tf` no módulo** carrega `required_providers` também (sem `required_version`, sem bloco `provider`) — é como o módulo declara de que precisa sem impor onde rodar.
- **`.terraform.lock.hcl` vai versionado no git**, em cada pasta de ambiente. Sem ele o `~>` é só uma intenção; o lock é o que garante que o mesmo provider seja usado na sua máquina, na do colega e no CI.

Ao mexer em um projeto que já tem `required_providers`, consulte a versão atual do registry e compare: se estiver atrás, aponte a diferença e proponha o upgrade — não faça o bump silenciosamente junto com outra mudança, porque um major de provider merece um plan próprio.

---

## Antes de entregar

Passe por esta lista — cada item mapeia direto em uma das quatro regras e é verificável olhando os arquivos:

- [ ] Nenhum `resource` no root de um ambiente (só `module` e, se necessário, `data`)
- [ ] Todo módulo tem `variables.tf` com `type` + `description` em cada variável, e `outputs.tf` com o que o consumidor precisa
- [ ] Nenhum bloco `provider` dentro de módulo — só `required_providers`
- [ ] Um diretório por ambiente, cada um com `backend` e `terraform.tfvars` próprios
- [ ] Nenhuma referência a `terraform.workspace` e nenhum comando `terraform workspace` no que foi entregue
- [ ] Todo `source` aponta para caminho local ou repositório da organização — nenhum do registry público
- [ ] A versão em cada `required_providers` veio de consulta ao registry nesta sessão, não de memória
- [ ] `terraform fmt` e `terraform validate` passam
