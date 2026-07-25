# Stack Node.js

## Onde está cada evidência

| Evidência | Onde procurar |
|---|---|
| Versão do runtime | `engines.node` no `package.json`, `.nvmrc`, `.node-version`. Ausente → use a LTS atual |
| Gerenciador de pacotes | qual lockfile existe, ou o campo `packageManager` no `package.json` |
| Comando de start | `scripts.start`; se ausente, o campo `main` |
| Porta | o `app.listen(...)` / `server.listen(...)` no entrypoint. Comum estar hardcoded |
| Env vars | ocorrências de `process.env.` — leia junto o operador `\|\|` que define o default |
| Serviços de dependência | os drivers nas `dependencies`: `pg`, `mysql2`, `mongoose`, `redis`/`ioredis`, `amqplib`, `kafkajs` |
| Etapa de build | `scripts.build`, presença de `tsconfig.json`, `vite.config`, `next.config`, `webpack.config` |
| Health | rotas `/health`, `/healthz`, `/ready`, ou um router de health importado no entrypoint |

O padrão `process.env.X || 'default'` é a fonte mais confiável do contrato de env, porque carrega o valor **e** o default na mesma linha:

```js
const DB_HOST = process.env.DB_HOST || "localhost";
const DB_PORT = parseInt(process.env.DB_PORT, 10) || 5432;
```

## Lockfile → comando de install

| Lockfile | Instalação determinística |
|---|---|
| `package-lock.json` | `npm ci --omit=dev` |
| `yarn.lock` (Yarn 1) | `yarn install --frozen-lockfile --production` |
| `yarn.lock` (Yarn 2+/Berry) | `yarn install --immutable` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile --prod` |
| nenhum | `npm install --omit=dev` — e avise que o build não é reprodutível |

`npm ci` exige que o lockfile esteja em sincronia com o `package.json` e apaga o `node_modules` antes de instalar. É o que garante que a imagem tem exatamente as versões testadas.

## Armadilhas de CWD

Express resolve vários caminhos a partir do **diretório de trabalho do processo**, não do arquivo de código:

| Padrão | Resolve a partir de | Risco |
|---|---|---|
| `express.static('static')` | CWD | alto — 404 silencioso em todo asset |
| `app.set('views', 'views')` e o default do EJS/Pug | CWD | alto — erro só quando a rota é acessada |
| `fs.readFileSync('./config.json')` | CWD | alto |
| `require('./modulo')` | diretório do arquivo | seguro |
| `path.join(__dirname, 'static')` | diretório do arquivo | seguro |

A presença de `__dirname` indica que o autor tratou o problema. A ausência dele, combinada com caminhos sem `/` inicial, é o sinal de que o `WORKDIR` precisa ser exatamente a raiz da aplicação.

Verificação rápida na investigação: se o projeto roda hoje com `cd src && npm start`, então `src/` é a raiz da aplicação e o conteúdo dele — não a pasta — vai para o `WORKDIR`.

```dockerfile
# Ruim — espelha o repositório, quebra os caminhos relativos
COPY src/ ./src/
CMD ["node", "src/server.js"]

# Bom — o conteúdo de src/ vira a raiz do WORKDIR
COPY src/ ./
CMD ["node", "server.js"]
```

## Dockerfile — JavaScript puro (sem build)

```dockerfile
# syntax=docker/dockerfile:1
ARG NODE_VERSION=22-alpine

FROM node:${NODE_VERSION} AS deps
WORKDIR /app
# Só os manifestos: esta camada só reconstrói quando as dependências mudam
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

FROM node:${NODE_VERSION} AS runtime
# Init como PID 1: encaminha SIGTERM ao node e faz reap de zumbis
RUN apk add --no-cache dumb-init
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node src/ ./
USER node
EXPOSE 8080
# fetch é global no Node 18+ — evita instalar curl só para o healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:8080/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "server.js"]
```

## Dockerfile — TypeScript / com etapa de build

Três stages: o build precisa das devDependencies, o runtime não pode carregá-las.

```dockerfile
# syntax=docker/dockerfile:1
ARG NODE_VERSION=22-alpine

FROM node:${NODE_VERSION} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci

FROM node:${NODE_VERSION} AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build
# Descarta as devDependencies do node_modules que vai para o runtime
RUN npm prune --omit=dev

FROM node:${NODE_VERSION} AS runtime
RUN apk add --no-cache dumb-init
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
USER node
EXPOSE 3000
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/index.js"]
```

## Notas

- **Alpine e binários nativos:** pacotes com extensão nativa (`bcrypt`, `sharp`, `canvas`, `node-gyp`) compilam contra musl no Alpine. Se falhar em runtime com erro de shared library, troque os dois stages para `-slim` (Debian/glibc) — nunca só um deles.
- **Frameworks com output próprio:** Next.js com `output: 'standalone'` gera `.next/standalone` já com as dependências resolvidas; copie esse diretório em vez do `node_modules` inteiro.
- **`npm prune --omit=dev`** no stage de build é o que evita ter que reinstalar as dependências de produção do zero num quarto stage.
