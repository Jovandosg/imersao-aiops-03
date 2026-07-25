# Stack .NET

## Onde está cada evidência

| Evidência | Onde procurar |
|---|---|
| Versão do runtime | `<TargetFramework>` no `.csproj` (`net8.0`, `net9.0`); `global.json` pina a versão do SDK |
| Projeto de entrada | o `.csproj` com `<OutputType>Exe</OutputType>`, ou o único com `Program.cs` |
| Nome do assembly | `<AssemblyName>`; ausente, é o nome do `.csproj` |
| Porta | `ASPNETCORE_URLS` ou `ASPNETCORE_HTTP_PORTS`; seção `Kestrel:Endpoints` no `appsettings.json` |
| Env vars | `appsettings.json` + `appsettings.{Environment}.json`, sobrescritos por variável de ambiente |
| Serviços de dependência | `Npgsql`, `Microsoft.Data.SqlClient`, `Pomelo.EntityFrameworkCore.MySql`, `StackExchange.Redis`, `MongoDB.Driver`, `RabbitMQ.Client` |
| Migration | pacote `Microsoft.EntityFrameworkCore.Design`, diretório `Migrations/`, ou `db.Database.Migrate()` no `Program.cs` |
| Health | `AddHealthChecks()` + `MapHealthChecks("/health")` |

Dois pontos não-óbvios que definem o contrato:

**A porta default mudou.** Até o .NET 7 as imagens de container escutavam na **80**; a partir do .NET 8 escutam na **8080**, para permitir rodar como non-root. Não assuma — confira o `TargetFramework`.

**O separador de seção em variável de ambiente é `__` (dois underscores).** É assim que se sobrescreve configuração aninhada do `appsettings.json`, e é o contrato de env real da aplicação:

```json
{ "ConnectionStrings": { "Default": "Host=localhost;Database=app" } }
```
```yaml
environment:
  ConnectionStrings__Default: "Host=db;Database=app;Username=app;Password=..."
```

**`launchSettings.json` não é fonte de verdade.** Ele só vale para `dotnet run` na máquina do desenvolvedor e é ignorado em container.

## Restore e cache

O padrão é copiar só os `.csproj` (preservando a estrutura de diretórios da solution), rodar `restore`, e só então copiar o código:

```dockerfile
COPY ["src/Api/Api.csproj", "src/Api/"]
COPY ["src/Domain/Domain.csproj", "src/Domain/"]
RUN dotnet restore "src/Api/Api.csproj"
COPY . .
```

`packages.lock.json` existe mas é opt-in (`<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>`). Quando presente, use `dotnet restore --locked-mode` para garantir build reprodutível.

## Armadilhas de CWD

| Padrão | Resolve a partir de | Risco |
|---|---|---|
| `wwwroot` (estáticos) | `ContentRootPath`, que por default é o **CWD** | alto |
| `appsettings.json` | `ContentRootPath` | alto — sobe com configuração default silenciosamente |
| `Directory.GetCurrentDirectory()` no builder de config | CWD | alto |
| `AppContext.BaseDirectory` | diretório do assembly | seguro |
| Recurso embutido (`EmbeddedResource`) | assembly | seguro |

Como `ContentRootPath` cai no CWD, o `WORKDIR` precisa ser o diretório onde o `publish` colocou os arquivos — incluindo `wwwroot` e os `appsettings.*.json`. O `dotnet publish` já organiza tudo junto na pasta de saída; o erro aparece quando alguém copia só a DLL.

## Dockerfile

```dockerfile
# syntax=docker/dockerfile:1
ARG DOTNET_VERSION=8.0

FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION}-alpine AS build
WORKDIR /src
# Só os manifestos primeiro — o restore é a etapa cara
COPY ["src/Api/Api.csproj", "src/Api/"]
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet restore "src/Api/Api.csproj"
COPY . .
# UseAppHost=false não gera o executável nativo — desnecessário, o entrypoint é `dotnet App.dll`
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish "src/Api/Api.csproj" -c Release -o /app/publish \
    --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION}-alpine AS runtime
WORKDIR /app
COPY --from=build /app/publish ./
# APP_UID é definido pelas imagens oficiais .NET 8+ (uid 1654)
USER $APP_UID
EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["dotnet", "Api.dll"]
```

## Notas

- **`ASPNETCORE_URLS=http://+:8080`** — o `+` faz o Kestrel escutar em todas as interfaces. Sem isso, dependendo da configuração, ele escuta só em localhost e o container fica inalcançável mesmo com a porta publicada.
- **Use a imagem `aspnet` no runtime, não a `sdk`.** A `sdk` tem compilador e ferramentas: passa de 800 MB, contra ~110 MB da `aspnet-alpine`.
- **`dotnet ef database update` não roda a partir da imagem de runtime** — o comando exige o SDK, que não está lá. As saídas são: gerar um *migration bundle* no stage de build (executável autocontido), rodar as migrations como um serviço one-shot no compose, ou chamar `db.Database.Migrate()` no start da aplicação.
- **Alpine e ICU:** as imagens Alpine vêm sem as bibliotecas de globalização. Se a aplicação depende de formatação por cultura, ou instale `icu-libs`, ou use a variante Debian. `InvariantGlobalization=true` só é opção se a aplicação não usa cultura.
- **O certificado HTTPS de desenvolvimento não vai para o container.** TLS termina no proxy/ingress; a aplicação em container serve HTTP puro.
