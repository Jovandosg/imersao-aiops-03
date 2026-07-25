---
name: containerizar-aplicacao
description: >
  Coloca uma aplicação em container Docker de ponta a ponta: investiga o repositório para derivar o
  contrato de containerização (porta, variáveis de ambiente e seus defaults, serviços de dependência,
  caminhos relativos ao CWD), gera Dockerfile, .dockerignore e compose, builda, sobe a stack e valida
  que a aplicação realmente funciona dentro do container. Use sempre que o usuário disser "coloca essa
  aplicação em container", "conteineriza esse projeto", "cria o Dockerfile", "preciso rodar isso no
  Docker", "monta o docker-compose", "sobe esse projeto com os serviços dele", ou apontar um repositório
  querendo executá-lo em container. Ative mesmo quando o pedido parecer parcial — quem pede só o
  Dockerfile precisa que ele funcione, e isso inclui descobrir os serviços de dependência e provar o
  comportamento depois de subir. Ative também para revisar, corrigir ou otimizar artefatos Docker que já
  existem no projeto. NÃO acione para: manifestos Kubernetes (Deployment, Service, Helm), pipelines de
  CI/CD, publicação de imagem em registry, ou debug de aplicação que já roda em container em produção.
---

# Containerizar Aplicação

Containerizar é um problema de **investigação**, não de template. O Dockerfile é a parte fácil — o que decide se a coisa funciona é ter descoberto, antes de escrever qualquer linha, em que porta a aplicação escuta, de quais serviços ela depende, e de qual diretório ela espera ler os próprios arquivos.

O fluxo tem cinco fases, em ordem. Cada uma só começa quando a anterior fechou:

1. **Investigar** — derivar o contrato de containerização a partir do código
2. **Gerar** — `.dockerignore`, `Dockerfile`, compose
3. **Buildar** — a imagem compila
4. **Subir** — a stack sobe junto com os serviços de dependência
5. **Validar comportamento** — a aplicação funciona *dentro* do container

As duas pontas são as que costumam ser puladas, e é exatamente onde as falhas moram: pular a fase 1 produz um Dockerfile chutado; parar na fase 4 entrega um container `healthy` que não serve.

## Quando aprofundar

| Sintoma / situação | Reference |
|---|---|
| Identificou a stack e precisa saber onde procurar cada evidência | `references/stack-node.md`, `stack-python.md`, `stack-go.md`, `stack-java.md`, `stack-dotnet.md` |
| Assets estáticos, templates ou arquivos de config dão 404 / "not found" dentro do container | o `stack-*` da linguagem, seção **Armadilhas de CWD** |
| A aplicação precisa de Postgres, MySQL, Redis, MongoDB ou RabbitMQ | `references/servicos-de-dependencia.md` |
| A aplicação sobe antes do banco aceitar conexão e morre no boot | `references/servicos-de-dependencia.md` |
| Chegou na fase 5, ou o container está `healthy` mas a aplicação não responde direito | `references/validacao-de-comportamento.md` |

---

## Fase 1 — Investigar

**Não escreva nenhum arquivo nesta fase.** O objetivo é sair dela com o contrato de containerização inteiro na mão. Cada evidência abaixo decide alguma coisa concreta no artefato final — investigar não é ler o projeto por educação, é coletar o que falta para não chutar.

| Evidência | Onde procurar | O que isso decide |
|---|---|---|
| Stack e versão do runtime | manifesto de dependências, `.nvmrc` / `.python-version` / `go.mod`, campo `engines` | a base image e a tag |
| Lockfile existe? | ao lado do manifesto | instalação determinística (`npm ci`) ou não (`npm install`) |
| Comando de start | script `start`, `Procfile`, `main`, o README | o `CMD` |
| Porta de escuta | o `listen` / `bind` no entrypoint — frequentemente hardcoded | o `EXPOSE` e o mapeamento no compose |
| Endereço de bind | o mesmo `listen`: `127.0.0.1` ou `0.0.0.0`? | se a aplicação será **alcançável de fora do container** |
| Contrato de env vars **com seus defaults** | onde a config é lida: `process.env`, `os.getenv`, `@Value`, `IConfiguration` | quais serviços entram no compose **e com quais credenciais** |
| Serviços de dependência | o driver/dialeto nas dependências + as env vars de conexão | os serviços do compose |
| Caminhos relativos ao CWD | strings de caminho sem `/` inicial e sem `__dirname` / `Path.Combine` | o `WORKDIR` e o layout do `COPY` |
| Endpoints de health | rotas `/health`, `/ready`, `/healthz`, actuator | o `HEALTHCHECK` e o `condition: service_healthy` |
| Etapa de build | script `build`, `tsconfig.json`, bundler, `pom.xml` | se precisa de um stage de build separado |
| Acesso a dependência no boot | conexão, migration ou sync de schema chamados no start | se o app precisa **esperar** o serviço ficar healthy |
| Escrita em disco | uploads, log em arquivo, SQLite | se precisa de volume |

Onde cada uma dessas evidências mora em cada linguagem está no `references/stack-*.md` correspondente. Leia **só** o da stack detectada.

### Feche a fase com o contrato escrito

Antes de gerar qualquer arquivo, escreva o contrato. Ele cabe em poucas linhas e é o que transforma leitura de código em decisão de projeto:

```
Stack:       Python 3.12 (requires-python no pyproject; uv.lock → uv sync --frozen --no-dev)
Start:       gunicorn --bind 0.0.0.0:8000 loja.wsgi:app   (Procfile)
Porta:       8000 (--bind no Procfile)
Bind:        0.0.0.0, explícito — ok
Depende de:  PostgreSQL e Redis (psycopg + redis nas dependências)
Env:         DATABASE_URL=postgresql://loja:loja@localhost:5432/loja
             REDIS_URL=redis://localhost:6379/0
             SECRET_KEY — sem default, obrigatória (loja/config.py:14)
CWD:         templates via Flask são relativos ao módulo (seguros), MAS
             open('regras.yaml') em loja/config.py:22 resolve pelo CWD
             → o WORKDIR precisa conter regras.yaml
Health:      GET /healthz
Build:       nenhum — assets já versionados no repo
Volume:      uploads gravados em ./media → volume nomeado
```

Esses defaults não são detalhe: espelhá-los no compose é o que faz a stack subir sem nenhuma configuração manual. Variável **sem** default, como o `SECRET_KEY` acima, é o caso em que o `.env.example` se justifica — gere um valor de desenvolvimento no compose e sinalize que produção precisa do seu.

> **Heurística de parada:** se você não sabe dizer em que porta a aplicação escuta e de quais serviços externos ela depende, a investigação não terminou. Escrever o Dockerfile agora é adivinhar, e o erro só vai aparecer na fase 5 — ou pior, em produção.

> **Se não está no código, não existe.** Não invente uma variável `PORT` que ninguém lê, um `/health` que não existe, ou um `NODE_ENV` que a aplicação ignora. Configuração decorativa é pior que configuração ausente: dá falsa segurança e evapora no primeiro debug.

### Quando já existe Dockerfile no projeto

Investigue do mesmo jeito. O artefato existente é **evidência, não verdade** — ele documenta o que alguém entendeu na época em que escreveu, e o código documenta o que a aplicação faz hoje. Derive o contrato do código primeiro, depois confronte: cada divergência entre o artefato e o contrato é um achado, com o trecho dos dois lados.

---

## A armadilha do CWD

Muita aplicação resolve caminhos **relativos ao diretório de trabalho do processo**, não à localização do arquivo de código. Quando isso acontece, o `WORKDIR` deixa de ser uma escolha estética e vira parte do contrato.

O modo de falha é traiçoeiro porque não é barulhento: a imagem builda, o container sobe, o healthcheck passa, `GET /` responde 200 — e todo CSS, JS e imagem retorna 404. Nenhuma validação superficial pega isso.

```dockerfile
# Ruim — preserva a estrutura do repositório, quebra os caminhos relativos
WORKDIR /app
COPY src/ ./src/
CMD ["node", "src/server.js"]
# o processo roda com CWD=/app, mas express.static('static') procura /app/static
# e o arquivo real está em /app/src/static → 404 em todo asset

# Bom — o WORKDIR é o diretório de onde a aplicação espera ler
WORKDIR /app
COPY src/ ./
CMD ["node", "server.js"]
# CWD=/app, e /app/static existe
```

A regra: **o `WORKDIR` é ditado por onde a aplicação espera estar, não pela estética do repositório.** Se o código roda hoje com `cd src && npm start`, então `src/` é a raiz da aplicação e é o conteúdo dele que vai para o `WORKDIR`.

Procure por caminhos relativos em: servir de estáticos, diretório de templates/views, leitura de arquivos de config, diretório de migrations, e caminhos de upload. As armadilhas específicas de cada framework estão nos `references/stack-*.md`.

---

## A armadilha do bind address

Da mesma família: silenciosa, e o container fica `healthy` enquanto ninguém consegue acessar.

Uma aplicação que escuta em `127.0.0.1` só aceita conexões vindas de **dentro do próprio container**. O mapeamento de portas do Docker entrega o tráfego na interface externa do container, onde ninguém está escutando — o resultado é connection refused a partir do host, com o processo rodando normalmente e o healthcheck (que roda de dentro) passando.

Em container, a aplicação precisa escutar em `0.0.0.0`.

```
# Ruim — inalcançável de fora, mesmo com a porta publicada
app.listen(3000, '127.0.0.1')
uvicorn.run(app, host="127.0.0.1")

# Bom
app.listen(3000, '0.0.0.0')
uvicorn.run(app, host="0.0.0.0")
```

Vários frameworks fazem bind em localhost por **default**, sem que isso apareça no código: Flask (`app.run()`), Fastify, Vite em modo preview. Quando o bind vem de variável de ambiente ou flag, resolva pelo compose ou pelo `CMD`. Quando está hardcoded no código, isso é um achado a reportar — a skill não altera o código da aplicação por conta própria.

---

## Fase 2 — Gerar

### `.dockerignore` primeiro

Escreva antes de qualquer build. Sem ele, o `node_modules` / `.venv` / `target` local entra no build context: o build fica lento, e — pior — um `COPY . .` sobrescreve as dependências que você acabou de instalar na imagem por binários compilados para o SO do host. Também é o que impede `.env` e `.git` de vazarem para dentro da imagem.

Cubra sempre: diretório de dependências instaladas, `.git`, `.env*` (com exceção de `.env.example`), artefatos de build local, arquivos de editor/SO, e os próprios arquivos Docker.

**Use `**/node_modules`, não `node_modules`.** Quando a aplicação vive num subdiretório (`src/`, `apps/api/`), o `npm install` local cria `src/node_modules` — e um padrão ancorado na raiz não pega isso. O mesmo vale para `**/.venv`, `**/target`, `**/bin`. É a falha que o `.dockerignore` existe para evitar, passando justamente por causa do padrão errado.

### Dockerfile

Quantos stages:

| Natureza do artefato | Stages | Por quê |
|---|---|---|
| Compilada (Go, Rust, Java, .NET) | obrigatório | o runtime não precisa do compilador — de ~1 GB para dezenas de MB |
| Transpilada (TypeScript, bundlers) | obrigatório | saem o toolchain e as devDependencies |
| Interpretada com extensão nativa (`psycopg2`, `node-gyp`) | sim | sai o `build-essential`; os stages precisam da **mesma libc**, senão o `.so` não carrega |
| Interpretada pura | 2 (deps + runtime) | isola o install para o cache não cair a cada commit de código |

Checklist do artefato — cada item existe por um motivo, não por cerimônia:

- **Tag pinada**, nunca `latest` — `latest` significa que o conteúdo da sua imagem muda sem você saber
- **Manifesto antes do código**: copie o manifesto, instale, só então copie o resto. Invertido, cada commit reinstala tudo
- **Instalação determinística** quando há lockfile — `npm ci`, não `npm install`
- **Usuário non-root** no runtime, com o ownership ajustado antes do `USER`
- **Forma exec** (`CMD ["node", "server.js"]`), não forma shell — é o que faz o `SIGTERM` chegar no processo
- **PID 1 que encaminha sinais** — a maioria dos runtimes não faz reap de zumbis nem trata sinais como PID 1. Use um init (`dumb-init`, `tini`, ou `init: true` no compose)
- **`HEALTHCHECK`** apontando para o endpoint de health que a investigação encontrou. Se o runtime já sabe fazer HTTP (Node com `fetch`, Python com `urllib`), use isso em vez de instalar `curl` só para o healthcheck
- **Só o necessário atravessa o `COPY --from`** — o artefato e as dependências de runtime, nunca o diretório de build inteiro

### Compose

O compose é derivado do contrato da fase 1, não de um template. Duas regras carregam quase tudo:

**Espelhe os defaults da aplicação.** As variáveis se dividem em duas classes, e confundi-las é o que faz a stack subir sem conectar:

```yaml
environment:
  DB_HOST: db                               # MUDA — nome do serviço na rede do compose, nunca localhost
  DB_DATABASE: ${DB_DATABASE:-kubedevnews}  # HERDA — default idêntico ao que o código já usa
  DB_USERNAME: ${DB_USERNAME:-kubedevnews}  # HERDA
```

Só o endereço das dependências muda: `localhost` vira o nome do serviço. O resto **herda** — se o código assume `DB_USERNAME=kubedevnews`, o serviço de banco precisa criar exatamente esse usuário. Inventar um default diferente no compose (`${DB_DATABASE:-app}`) cria um terceiro ambiente que ninguém testou.

O alvo é **zero-config**: `docker compose up` tem que funcionar sem `.env`. Se o projeto realmente exigir um, gere o `.env.example` e diga isso — mas o caminho feliz não pode depender dele.

Espelhar defaults reais exige atenção ao escaping: em YAML, valor com `#` precisa de aspas (`"Pg#123"`), senão o resto da linha vira comentário; na interpolação do Compose, um `$` literal se escreve `$$`.

**Amarre a ordem de inicialização a um healthcheck real.** `depends_on` sozinho espera o container *iniciar*, não o serviço ficar *pronto* — e um app que conecta no banco durante o boot morre nessa janela.

```yaml
# Ruim — o app sobe e tenta conectar antes do Postgres aceitar conexão
depends_on:
  - db

# Bom — espera o banco responder de verdade
depends_on:
  db:
    condition: service_healthy
```

Além disso: declare `name:` no compose para dar namespace ao projeto; use **named volume** para dados persistentes; rede dedicada; e publique portas de serviços internos só no loopback (`127.0.0.1:5432:5432`) — expor o banco de alguém em `0.0.0.0` não é necessário para a aplicação funcionar.

**Evite `container_name`.** Ele troca o nome gerado pelo Compose (que é derivado do projeto) por um nome global fixo — e nome global é exatamente o que colide com um container órfão, ou com uma segunda instância do próprio projeto. Sem `container_name`, o conflito de nomes simplesmente não acontece.

Os blocos prontos de cada serviço, com healthcheck que de fato funciona, estão em `references/servicos-de-dependencia.md`.

---

## Fase 3 — Buildar

Builde o target final. Se não constrói, pare e corrija — as fases seguintes não têm o que validar.

Ao terminar, registre o tamanho da imagem — mas o número sozinho não diz nada. Compare com a faixa esperada da stack:

| Stack | Faixa típica | Acima disso, procure |
|---|---|---|
| Go / Rust em distroless ou scratch | 10–40 MB | assets não embutidos, runtime cheio demais |
| Node alpine, sem etapa de build | 150–300 MB | devDependencies instaladas, `.dockerignore` furado |
| Python slim | 200–400 MB | toolchain de build vazando para o runtime, cache do pip |
| Java JRE alpine | 200–350 MB | imagem `jdk` no runtime em vez de `jre` |
| .NET aspnet alpine | 110–250 MB | imagem `sdk` no runtime |

Estourar a faixa é sinal, não veredito — um projeto com muitas dependências legitimamente pesa mais. O que não pode é você não saber explicar o excedente.

---

## Fase 4 — Subir

Suba a stack e espere os serviços ficarem healthy antes de concluir qualquer coisa.

### Conflito com recursos que já existem

A regra é **inspecionar antes de destruir**: descubra de onde vem o recurso conflitante, confirme se o volume de dados é o mesmo que a sua stack usa, e remova só o que for necessário — preservando dados.

| Conflito | Como aparece | O que fazer |
|---|---|---|
| Nome de container ocupado | `Conflict. The container name "/x" is already in use` | `docker inspect` no órfão: veja os labels `com.docker.compose.*` e os `Mounts`. Confirme que o volume dele não é de outra stack e remova **só o container** (`rm -f`, sem `-v`) |
| Porta do host ocupada | `bind: address already in use` | ache o dono (`lsof -nP -iTCP:<porta> -sTCP:LISTEN`, `docker ps --filter publish=<porta>`). Se for processo do usuário, **pergunte**; ou publique em outra porta via `${APP_PORT:-...}` |
| Volume homônimo com dados de outro projeto | sobe, mas o schema está estranho ou a autenticação falha | `docker volume inspect` e o label de projeto. Renomeie o volume **no seu compose** antes de encostar no volume existente |
| Rede / subnet | `Pool overlaps with other one` | remova a rede órfã, ou não fixe subnet |
| Tag de imagem já em uso | o build sobrescreve a imagem de outro projeto | dê à imagem um nome derivado do projeto (`<projeto>:local`) |

```bash
# Bom — entende o conflito antes de agir
docker ps -a --filter "name=<nome>" --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
docker inspect <nome> --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{"\n"}}{{end}}'

# Ruim — apaga o volume de dados de alguém sem saber
docker compose down -v
```

Remover container é reversível; remover volume não é. Quando o recurso conflitante não for claramente descartável, pergunte ao usuário antes.

---

## Fase 5 — Validar comportamento

**`healthy` não é validação.** Um container pode estar rodando, non-root, com healthcheck verde, e ainda assim: não conectar no banco, servir 404 em todo asset, ou perder os dados no primeiro restart. O status diz que o processo está de pé; não diz que a aplicação funciona.

Valide por dimensão. Cada linha pega uma falha que as outras não pegam:

| Dimensão | Como provar | Aplica quando |
|---|---|---|
| Processo | usuário non-root, PID 1 esperado, `RestartCount=0` após ~30s | sempre |
| Alcançabilidade | responde na porta publicada, **a partir do host** | expõe porta |
| Health | os endpoints de health que o código declara respondem | há endpoint de health |
| Renderização | a resposta **contém um marcador do conteúdo esperado**, e nenhum erro de template | serve HTML |
| Assets estáticos | 200 **com content-type coerente** em cada asset referenciado pela página | serve CSS/JS/imagem |
| Integração | a aplicação conectou de fato — as tabelas foram criadas, o `/ready` reflete a dependência | há banco/cache/fila |
| Caminho de escrita | grava um registro sentinela via API, lê de volta pela API **e confirma direto no serviço de dados** | há banco/cache |
| Persistência | o sentinela sobrevive a `down` + `up` (sem `-v`) | há volume |
| Parada limpa | `docker compose stop` retorna rápido | sempre |
| Limpeza | sentinela removido, com contagem antes/depois | criou dados de teste |

Os comandos exatos de cada linha estão em `references/validacao-de-comportamento.md`.

Quatro armadilhas que anulam a validação inteira:

- **Conferir só `GET /`.** A home responde 200 enquanto todo o CSS retorna 404 — é o modo de falha da armadilha do CWD.
- **Olhar só o status do asset, sem o content-type.** Um fallback de SPA devolve `200 text/html` para arquivo inexistente. `text/html` num `.css` é um 404 disfarçado.
- **Validar de dentro com `docker compose exec ... curl`.** A imagem mínima que este fluxo produz não tem `curl`, e testar de dentro não prova que a porta está publicada nem que o bind é `0.0.0.0`. Teste **do host**.
- **Provar persistência com `restart`.** `restart` reinicia o processo no **mesmo container**, com o mesmo filesystem — o dado sobreviveria até se estivesse na camada gravável. Só `down` + `up` recria o container e prova que o volume está realmente carregando o estado.

Sobre a parada limpa: se o `stop` demora **exatamente 10 segundos**, o Docker matou o processo com `SIGKILL` depois do timeout padrão. Isso significa que o `SIGTERM` não chegou — quase sempre forma shell no `CMD` ou ausência de um init como PID 1.

### Relatório final

Termine com uma tabela de evidências, uma linha por dimensão validada.

**Evidência, não adjetivo.** `uid=1000(node)` prova; "roda como non-root" é opinião. `RestartCount=0 após 30s` prova; "container estável" não.

Dimensão não aplicável entra como `n/a` **com a razão** (`worker não expõe porta`) — não some da tabela. Dimensão que não pôde ser verificada entra como não executada, com o motivo. Item omitido é lido como item aprovado.

Se você encontrou no caminho problemas fora do escopo de containerização (secret hardcoded, dependência de teste no manifesto de produção), liste-os ao final marcados explicitamente como **não corrigidos**.

---

## O que esta skill NÃO faz

- Manifestos Kubernetes, Helm charts
- Pipelines de CI/CD
- Publicação de imagem em registry, assinatura, scan de vulnerabilidades em pipeline
- Correção de bugs da aplicação — se o app está quebrado fora do container, containerizar não conserta

---

## Anti-patterns

- Escrever o Dockerfile antes de saber a porta e os serviços de dependência — o resto vira tentativa e erro
- Tomar o Dockerfile herdado como fonte do contrato — ele documenta o que alguém entendeu na época, o código documenta hoje
- Inventar variável, porta ou `/health` que o código não usa — configuração decorativa, falsa segurança
- `WORKDIR` escolhido pela estética do repositório em vez dos caminhos relativos que a aplicação usa — 404 silencioso em todo asset
- Aplicação escutando em `127.0.0.1` dentro do container — `healthy` por dentro, connection refused por fora
- Compose com credenciais que divergem dos defaults do código — a stack sobe e o app não conecta
- Default inventado no compose (`${DB_DATABASE:-app}`) — cria um terceiro ambiente que ninguém testou
- `compose up` que exige um `.env` que você não gerou — o "funciona na minha máquina" fabricado por você mesmo
- `depends_on` sem `condition: service_healthy` quando o app conecta no boot — falha intermitente, "às vezes sobe"
- `container_name` fixo sem motivo — é o que colide com órfão e com uma segunda instância do próprio projeto
- Tratar `up -d` bem-sucedido como aplicação funcionando — restart loop e falha de conexão passam despercebidos
- Validar só `GET /` e concluir que o front funciona
- Checar asset só pelo status, sem o content-type — o fallback devolve `200 text/html` para arquivo que não existe
- Validar de dentro do container com `docker compose exec curl` — a imagem mínima não tem `curl`, e não prova que a porta está publicada
- Provar persistência com `restart` — mesmo container, mesmo filesystem; não prova volume nenhum
- Deixar o registro sentinela no banco do usuário — poluição silenciosa
- Remover container órfão sem `inspect` antes — o volume dele podia ser o banco de outro projeto
- `docker compose down -v` para "limpar o conflito" — apaga dado de desenvolvimento que não é seu
- Buildar sem `.dockerignore` — build lento, e o `node_modules` do host sobrescreve o da imagem
- `COPY . .` antes do manifesto de dependências — invalida o cache a cada commit
- `latest` na base image — o conteúdo da imagem muda sem você saber
- Forma shell no `CMD` — o `SIGTERM` morre no shell e o container só para no timeout
- Instalar `curl` na imagem só para o `HEALTHCHECK` quando o runtime já sabe fazer HTTP
- Rodar como root em runtime
- Publicar a porta do banco em `0.0.0.0` — a aplicação não precisa disso, e a rede local passa a alcançar
- Entregar sem relatório de evidências — "deve funcionar" não é validação
