# Validação de comportamento

> **Quando ler:** você chegou na fase 5, ou o container está `healthy` e você não confia nele.

Esta validação prova que **a aplicação continua sendo a mesma dentro do container**. Não é a suíte de testes do projeto — a corretude da regra de negócio é etapa anterior, de outra responsabilidade. É a faixa entre "o processo está de pé" e "o código está certo", que é exatamente onde a containerização quebra.

## Por que "healthy" e "200 na raiz" não bastam

Três modos de falha que passam por qualquer validação superficial:

**O asset fantasma.** O código está em `/app/src`, o processo roda com CWD `/app`, e a aplicação serve estáticos por caminho relativo. A imagem builda, o container sobe, o healthcheck passa, `GET /` responde 200 — e todo CSS, JS e imagem retorna 404. A página existe, mas chega sem estilo nenhum. Foi exatamente esse o risco no kube-news, e o que evitou foi conferir os assets individualmente.

**O banco errado.** A aplicação tem um fallback para SQLite quando a conexão falha, ou o `DB_HOST` aponta para `localhost` (que dentro do container é o próprio container). A app sobe, responde, grava dados — num banco que não é o que você configurou. Só some quando o container é recriado.

**O volume decorativo.** O volume está declarado no compose mas montado no caminho errado, ou o serviço grava em outro diretório. Tudo funciona durante a sessão inteira. O dado desaparece no primeiro `down`/`up`.

Nenhum dos três aparece em `docker compose ps`.

---

## Processo e identidade

Como a skill desaconselha `container_name`, o nome do container é gerado pelo Compose — resolva pelo serviço em vez de escrevê-lo à mão:

```bash
APP=$(docker compose ps -q app)

docker compose exec -T app id                    # uid não pode ser 0
docker compose exec -T app ps -o pid,user,args   # quem é o PID 1
docker inspect "$APP" --format '{{.State.Health.Status}} restarts={{.RestartCount}}'
docker images <imagem> --format '{{.Size}}'
```

`RestartCount` diferente de zero depois de ~30s significa restart loop — o container "está rodando" porque acabou de subir de novo.

Em imagem sem shell (distroless, scratch), `exec` não funciona. Verifique pela imagem:

```bash
docker inspect <imagem> --format 'User={{.Config.User}} Entrypoint={{.Config.Entrypoint}} Cmd={{.Config.Cmd}}'
```

`User` vazio significa root.

## Alcançabilidade

Sempre **do host**, nunca com `exec`. Testar de dentro não prova que a porta está publicada nem que o bind é `0.0.0.0` — e a imagem mínima nem tem `curl`.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/
```

Connection refused com o container `healthy` é quase sempre bind em `127.0.0.1`.

## Renderização de template

Status 200 não distingue "página renderizada" de "página de erro renderizada". Procure um marcador do conteúdo esperado **e** a ausência de erro de template:

```bash
curl -s http://localhost:8080/ | grep -q "<marcador esperado>" && echo OK
```

As mensagens que denunciam template não resolvido:

| Engine | Mensagem |
|---|---|
| EJS / Express | `Failed to lookup view` |
| Jinja / Flask / Django | `TemplateNotFound`, `TemplateDoesNotExist` |
| Thymeleaf | `Error resolving template` |
| Go `html/template` | `pattern matches no files` |
| Razor | `InvalidOperationException: The view ... was not found` |

Todas essas costumam vir com status 500 — mas algumas aplicações capturam a exceção e devolvem 200 com uma página de erro amigável. Por isso o marcador positivo importa tanto quanto a ausência do erro.

## Assets estáticos — a sonda

Não escolha os caminhos a dedo: extraia os que a **própria página** referencia. Se a página pede, a página precisa receber.

```bash
BASE=http://localhost:8080
curl -s "$BASE/" \
  | grep -oE '(href|src)="[^"]+\.(css|js|mjs|png|svg|jpg|jpeg|gif|webp|avif|ico|woff2?)"' \
  | cut -d'"' -f2 | sort -u | head -10 \
  | while read -r asset; do
      case "$asset" in http*) url="$asset" ;; /*) url="$BASE$asset" ;; *) url="$BASE/$asset" ;; esac
      printf '%-45s %s\n' "$asset" \
        "$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$url")"
    done
```

Valide também as páginas internas, não só a home: o estado vazio de uma listagem costuma referenciar assets diferentes dos que aparecem com dados.

### O controle negativo

Quatro assets respondendo `200 text/css` ainda são compatíveis com um fallback que por acaso acerta o content-type. Peça um arquivo que você **sabe** que não existe e confirme que a aplicação devolve 404:

```bash
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' "$BASE/styles/nao-existe-mesmo.css"
# esperado: 404 — se vier 200, há fallback e a checagem positiva não vale nada
```

Sem esse passo, a sonda prova que *algo* responde, não que a aplicação está servindo os arquivos dela.

**O content-type é o discriminador, não o status.** Aplicações com fallback de SPA devolvem `200 text/html` para qualquer caminho que não existe — um `.css` respondendo `text/html` é um 404 disfarçado que passa por qualquer checagem baseada só em status.

| Resposta para `/styles/main.css` | Leitura |
|---|---|
| `200 text/css` | serve |
| `404 text/html` | não serve — e pelo menos é honesto |
| `200 text/html` | **não serve** — fallback mascarando o 404 |

## Integração com o serviço de dependência

Três camadas, e só a terceira prova de verdade:

1. **A aplicação diz que conectou** — log de conexão, `/ready` retornando 200. É a mais fraca: muitos ORMs logam sucesso com pool lazy, antes de qualquer query real.
2. **O serviço mostra o efeito do boot** — as tabelas foram criadas pelo sync/migration:
   ```bash
   docker compose exec -T db psql -U <user> -d <db> -c '\dt'
   ```
3. **O dado circula ponta a ponta** — a próxima seção.

## Caminho de escrita — o registro sentinela

Grave um registro **marcado**, para poder encontrá-lo e removê-lo depois com certeza.

**Derive o payload do handler da rota, não deste exemplo.** Um corpo que não bate com o que o handler espera devolve 500 ou estoura uma exceção — e você vai concluir que o container está quebrado quando o errado era o seu curl. Leia a rota antes de montar o `-d`.

```bash
# 1. Escreve pela API — payload no formato que ESTE handler espera
curl -sS -X POST http://localhost:8080/api/post \
  -H 'Content-Type: application/json' \
  -d '{"artigos":[{"title":"[validacao-container]","resumo":"sentinela","description":"registro de validacao"}]}' \
  -w '\nHTTP %{http_code}\n'

# 2. Lê de volta pela API — prova o caminho de leitura
curl -s http://localhost:8080/ | grep -c "validacao-container"

# 3. Confirma no serviço de dados — prova que é o banco certo
docker compose exec -T db psql -U <user> -d <db> \
  -c "SELECT id, title FROM \"Posts\" WHERE title LIKE '%validacao-container%';"
```

O passo 3 é o que pega o "banco errado". Sem ele, um fallback para SQLite dentro do container passaria nos passos 1 e 2 sem nenhum sinal.

## Persistência

```bash
# restart — NÃO prova volume
docker compose restart app

# down + up — prova
docker compose down          # sem -v!
docker compose up -d --wait
# o sentinela precisa continuar lá
```

| Operação | O que acontece | O que prova |
|---|---|---|
| `restart` | mesmo container, mesmo filesystem | só que o processo reinicia limpo |
| `down` + `up` | container recriado do zero | **que o volume está carregando o estado** |
| `down -v` | volume apagado | nada — destrói a evidência |

O erro comum é parar no `restart`. Como o container e sua camada gravável continuam os mesmos, o dado sobreviveria até se o volume não existisse.

## Parada limpa

Cronometre **o serviço da aplicação**, não a stack inteira — senão um banco lento mascara um app limpo, ou vice-versa:

```bash
time docker compose stop app
```

Se demorar **exatamente 10 segundos**, o Docker esperou o timeout padrão e matou o processo com `SIGKILL`. O `SIGTERM` não chegou. As causas, em ordem de frequência: forma shell no `CMD` (`CMD node server.js` em vez de `CMD ["node","server.js"]`), ausência de init como PID 1, ou a aplicação genuinamente não tratando o sinal.

Parada limpa importa mais do que parece: em produção é a diferença entre drenar conexões e cortar requisições no meio.

## Limpeza

```bash
docker compose exec -T db psql -U <user> -d <db> \
  -c "DELETE FROM \"Posts\" WHERE title LIKE '%validacao-container%';"
```

Reporte a contagem antes e depois. Se algum dado de teste não puder ser removido (não há endpoint de delete, o schema não permite), **declare isso no relatório** em vez de deixar silenciosamente.

---

## Matriz por natureza da aplicação

| Natureza | O que validar |
|---|---|
| Web com renderização no servidor | tudo: processo, alcançabilidade, template, assets, integração, escrita, persistência, parada |
| API JSON | tudo menos template e assets |
| SPA + backend separados | no backend, API; no frontend, alcançabilidade + assets (aqui o fallback de SPA é esperado, então valide um asset que você sabe que existe) |
| Worker / consumer | sem HTTP: publique uma mensagem de teste e observe o efeito no destino. Processo, integração, persistência e parada continuam valendo |
| Cron / job agendado | dispare o job manualmente e verifique o efeito; confirme que o container não fica em restart loop entre execuções |
| CLI / batch | rode com input de exemplo, compare a saída e confirme **exit code 0**. Aqui o critério é invertido: container que termina é sucesso |

---

## Como reportar

**Evidência, não adjetivo.** O número é a prova; o adjetivo é opinião.

```
# Ruim
Assets: ok
Persistência: funcionando
Segurança: container roda como non-root

# Bom
Assets:        /styles/main.css → 200 text/css · /img/logo.svg → 200 image/svg+xml
Persistência:  sentinela presente após down+up (1 registro)
Processo:      uid=1000(node), PID 1 = dumb-init, RestartCount=0 após 30s
```

Dimensão não aplicável entra como `n/a` **com a razão** (`worker não expõe porta`). Dimensão que não pôde ser verificada entra como não executada, com o motivo. Item omitido é lido como item aprovado.

## Erros comuns

- **Validar de dentro do container.** `docker compose exec app curl ...` — a imagem mínima não tem `curl`, e mesmo funcionando não prova publicação de porta nem bind correto.
- **Confiar no navegador.** Cache de disco entrega o CSS antigo e mascara o 404. Se for abrir no navegador, force um reload sem cache — mas prefira `curl`.
- **Medir persistência só com `restart`.** Não prova volume nenhum.
- **Checar asset só pelo status.** Sem o content-type, o fallback de SPA passa despercebido.
- **Esquecer o sentinela no banco.** Poluição silenciosa no ambiente do usuário.
- **Declarar aprovação sem a tabela.** O relatório é a prova, não o resumo dela.
