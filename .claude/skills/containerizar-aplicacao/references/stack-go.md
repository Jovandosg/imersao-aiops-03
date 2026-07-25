# Stack Go

## Onde está cada evidência

| Evidência | Onde procurar |
|---|---|
| Versão do runtime | a diretiva `go` no `go.mod`; opcionalmente `toolchain` |
| Qual binário construir | o layout `cmd/<nome>/main.go` — cada subdiretório é um binário diferente |
| Comando de start | não existe script; o binário compilado é o entrypoint |
| Porta | `http.ListenAndServe(":8080", ...)`, `r.Run(":8080")` no Gin, `app.Listen(":3000")` no Fiber |
| Env vars | `os.Getenv`, `os.LookupEnv`, `envconfig`, ou `viper.AutomaticEnv()` + `viper.SetDefault(...)` |
| Configuração por flag | `flag.String(...)` — se a config vem por flag e não por env, o `CMD` precisa passar os argumentos |
| Serviços de dependência | `lib/pq`, `jackc/pgx`, `go-sql-driver/mysql`, `redis/go-redis`, `mongo-driver`, `segmentio/kafka-go`, `rabbitmq/amqp091-go` |
| Health | rotas registradas no mux: `/health`, `/healthz`, `/readyz` |

Atenção a `flag`: Go tem uma cultura forte de configuração por linha de comando. Se o `main.go` define flags em vez de ler env, o contrato não está nas variáveis de ambiente — está no `CMD`.

## Lockfile → comando de install

`go.sum` é o lockfile e sempre acompanha o `go.mod`. Para aproveitar cache, baixe os módulos antes de copiar o código:

```dockerfile
COPY go.mod go.sum ./
RUN go mod download
COPY . .
```

Se existe diretório `vendor/`, o build usa ele por default — compile com `-mod=vendor` e não rode `go mod download`.

## Armadilhas de CWD

| Padrão | Resolve a partir de | Risco |
|---|---|---|
| `http.Dir("./static")` / `http.FileServer` | CWD | alto |
| `template.ParseGlob("templates/*.html")` | CWD | alto — pânico no start ou erro na primeira requisição |
| `os.ReadFile("config.yaml")`, `viper.AddConfigPath(".")` | CWD | alto |
| `//go:embed static templates` | **compilação** | seguro — não há nada a copiar |

`//go:embed` é o sinal mais forte que existe: se o projeto usa embed, os assets já estão dentro do binário e o runtime pode ser `scratch`. Se não usa, os diretórios precisam ser copiados **e** o `WORKDIR` precisa bater com o caminho relativo.

## Dockerfile — binário estático em distroless

```dockerfile
# syntax=docker/dockerfile:1
ARG GO_VERSION=1.23
ARG TARGET=./cmd/api

FROM golang:${GO_VERSION}-alpine AS build
WORKDIR /src
# Módulos primeiro: esta camada só cai quando go.mod/go.sum mudam
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
# CGO_ENABLED=0 produz binário estático — requisito para distroless/scratch
# -ldflags "-s -w" remove tabela de símbolos e debug info
ARG TARGET
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/app ${TARGET}

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
# distroless/static já traz ca-certificates e tzdata, e roda como nonroot (65532)
COPY --from=build /out/app /app
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

Se o projeto **não** usa `//go:embed`, copie também os diretórios de assets e defina o `WORKDIR` de acordo:

```dockerfile
WORKDIR /
COPY --from=build /src/templates ./templates
COPY --from=build /src/static ./static
```

## Notas

- **`CGO_ENABLED=0` é o que torna o binário estático.** Sem isso, o binário depende da libc do builder e não roda em `scratch` nem em distroless static. A dependência mais comum que força `CGO_ENABLED=1` é o `mattn/go-sqlite3` — nesse caso o runtime precisa ser Alpine ou Debian, não scratch.
- **`scratch` sem `ca-certificates` builda, sobe e morre na primeira chamada HTTPS** com `x509: certificate signed by unknown authority`. As imagens `distroless/static` já resolvem isso; com `scratch` puro, copie os certificados do stage de build.
- **Sem `/etc/passwd` não existe usuário nomeado.** Em `scratch`, o non-root é numérico: `USER 65532:65532`.
- **`HEALTHCHECK` em distroless não tem shell nem curl.** Ou você embute um subcomando de health no próprio binário (`/app -healthcheck`), ou deixa o healthcheck para o compose/orquestrador.
- **Sem `tzdata`, todo horário é UTC.** Se a aplicação formata data em fuso local, importe `_ "time/tzdata"` para embutir o banco de fusos no binário.
