# Runbook — Deploy do kube-news no Kubernetes

Procedimento de deploy da aplicação `kube-news` (Node/Express + Sequelize + PostgreSQL) em um cluster EKS, e o registro dos problemas que apareceram durante a execução real deste deploy — cada um com o sintoma observado, a causa e a correção.

Os erros documentados aqui não são hipotéticos: **todos aconteceram**. A seção [Problemas conhecidos](#problemas-conhecidos) existe porque cada um deles custou tempo, e vários se manifestam longe da causa.

- [Contrato da aplicação](#contrato-da-aplicação)
- [Pré-requisitos](#pré-requisitos)
- [Procedimento de deploy](#procedimento-de-deploy)
- [Verificação](#verificação)
- [Problemas conhecidos](#problemas-conhecidos)
- [Operações do dia a dia](#operações-do-dia-a-dia)
- [Rollback e teardown](#rollback-e-teardown)
- [Lições](#lições)

---

## Contrato da aplicação

Tudo abaixo saiu da leitura do código, não de suposição. Ao mudar a aplicação, **refaça esta leitura** — manifesto que aponta para um endpoint que o código não serve é configuração decorativa: parece certa e evapora no primeiro debug.

| Fato | Onde está no código |
|---|---|
| Escuta na porta `8080`, sem variável `PORT` | `src/server.js:81` — `app.listen(8080)` |
| `GET /health` — responde só pelo processo, não toca no banco | `src/system-life.js:22` |
| `GET /ready` — semântica de prontidão, controlada por `PUT /unreadyfor/:seconds` | `src/system-life.js:11` |
| `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `DB_SSL_REQUIRE` | `src/models/post.js:8-13` |
| Roda `sequelize.sync({alter: true})` no boot e **sai com exit 1** se o banco não responder | `src/models/post.js:59` |

Duas consequências desse contrato que definem o manifesto:

- A aplicação tem dois endpoints de health **genuinamente diferentes**, então liveness e readiness podem ter propósitos distintos de verdade.
- A aplicação **morre** se o banco não estiver de pé no boot. Isso não é coberto por probe nenhuma — ver [Problema 2](#problema-2--pods-em-crashloopbackoff-restarts-subindo-no-primeiro-apply).

### Ambiente de referência

| Item | Valor |
|---|---|
| Cluster | `kube-news-dev` (EKS, `us-east-1`) |
| Kubernetes | server `v1.36.2-eks`, client `v1.36.1` |
| Nodes | 2× `t3.medium`, arquitetura **amd64** |
| Máquina de build | Apple Silicon, arquitetura **arm64** |
| Registry | Docker Hub — `fabricioveronez/kube-news` |
| Manifesto | `k8s/kube-news.yaml` (arquivo único, 7 objetos) |

---

## Pré-requisitos

```bash
# Contexto do kubectl apontando para o cluster certo — confira SEMPRE antes do apply
kubectl config current-context
# esperado: arn:aws:eks:us-east-1:<account>:cluster/kube-news-dev

# Cluster acessível
kubectl get nodes

# Docker rodando e login no registry ativo
docker version --format '{{.Server.Version}}'
docker login          # se o push falhar com "unauthorized"
```

Se o contexto estiver errado, corrija antes de qualquer coisa:

```bash
aws eks update-kubeconfig --region us-east-1 --name kube-news-dev
```

> O manifesto tem `namespace: kube-news` escrito em todos os objetos, então um contexto errado não vai aplicar no namespace errado — mas vai aplicar no **cluster** errado. O `current-context` é a única defesa contra isso.

---

## Procedimento de deploy

### Passo 1 — Build da imagem

```bash
docker build --platform linux/amd64 -t fabricioveronez/kube-news:v1 .
```

**O `--platform linux/amd64` não é opcional.** A máquina de build é arm64 e os nodes do EKS são amd64. Sem a flag, o build passa, o push passa, o `kubectl apply` passa — e o pod quebra no cluster com `exec format error`. Ver [Problema 1](#problema-1--exec-format-error-no-pod).

Confira antes de gastar tempo com push:

```bash
docker image inspect fabricioveronez/kube-news:v1 --format 'Arch: {{.Architecture}} | OS: {{.Os}}'
# esperado: Arch: amd64 | OS: linux
```

### Passo 2 — Push para o registry

```bash
docker push fabricioveronez/kube-news:v1
```

Anote o digest da saída (`v1: digest: sha256:...`). Ele é a identidade real do que subiu — a tag é uma convenção, o digest é a garantia.

> **Sobre a tag:** `v1` é fixa por convenção, mas nada impede alguém de sobrescrevê-la no registry. Em produção, prefira tag derivada do build (SHA do commit, versão semântica) ou fixe o digest no manifesto: `image: fabricioveronez/kube-news@sha256:...`.

### Passo 3 — Apply dos manifestos

A senha do banco **não fica no arquivo versionado**. O YAML carrega o placeholder `<DB_PASSWORD>` e o valor real entra no pipe do apply:

```bash
export DB_PASSWORD='Pg#123'          # em produção: vem do gerenciador de secrets
sed "s|<DB_PASSWORD>|${DB_PASSWORD}|" k8s/kube-news.yaml | kubectl apply -f -
```

Saída esperada — 7 objetos, nesta ordem:

```
namespace/kube-news created
configmap/kube-news-config created
secret/kube-news-db created
deployment.apps/postgres created
service/postgres created
deployment.apps/kube-news created
service/kube-news created
```

A ordem dos documentos dentro do arquivo importa: Namespace primeiro, config antes dos workloads, banco antes da aplicação. O `kubectl apply -f` respeita a ordem do arquivo.

Confirme que o arquivo continua limpo:

```bash
grep -n 'password:' k8s/kube-news.yaml
# esperado: 60:  password: "<DB_PASSWORD>"
```

### Passo 4 — Acompanhar o rollout

```bash
kubectl rollout status deployment/postgres  -n kube-news --timeout=180s
kubectl rollout status deployment/kube-news -n kube-news --timeout=180s
```

Os dois devem terminar com `successfully rolled out`. Se travar, vá direto para [Problemas conhecidos](#problemas-conhecidos).

---

## Verificação

Não considere o deploy pronto porque os pods estão `Running`. `Running` só diz que o container não morreu.

### 1. Estado dos pods — incluindo a coluna que quase todo mundo ignora

```bash
kubectl get pods -n kube-news -o custom-columns=\
'POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,QOS:.status.qosClass,NODE:.spec.nodeName'
```

**`RESTARTS` acima de 0 num deploy novo é um achado, não ruído.** Foi exatamente essa coluna que revelou o [Problema 2](#problema-2--pods-em-crashloopbackoff-restarts-subindo-no-primeiro-apply). O pod estava `Running` e `Ready`; o contador denunciou que ele tinha morrido duas vezes antes de estabilizar.

`QOS` deve ser `Burstable` ou `Guaranteed` — **nunca `BestEffort`**. `BestEffort` significa que algum container ficou sem `resources` e é o primeiro da fila de despejo quando o nó apertar.

### 2. Endpoints — o teste que pega selector desalinhado

```bash
kubectl get endpointslice -n kube-news -o custom-columns=\
'NAME:.metadata.name,PORTS:.ports[*].port,IPS:.endpoints[*].addresses'
```

Esperado: um IP por pod pronto em cada Service.

```
kube-news-fv5dl   8080   [10.0.52.115],[10.0.47.102]
postgres-9q8st    5432   [10.0.49.181]
```

**Lista vazia = o `selector` do Service não casa com as labels do pod template.** Esse erro não produz mensagem em lugar nenhum: o `apply` retorna sucesso, o Service existe, o ClusterIP é atribuído, e a requisição simplesmente não chega. É o modo de falha mais silencioso do Kubernetes.

### 3. Teste funcional de dentro do cluster

```bash
kubectl run smoke --rm -i --restart=Never -n kube-news \
  --image=curlimages/curl:8.11.1 --quiet -- sh -c '
  curl -s -o /dev/null -w "GET  / ....... HTTP %{http_code}\n" -m 20 http://kube-news/
  curl -s -o /dev/null -w "GET  /health . HTTP %{http_code}\n" -m 20 http://kube-news/health
  curl -s -o /dev/null -w "GET  /ready .. HTTP %{http_code}\n" -m 20 http://kube-news/ready
  curl -s -m 20 -X POST http://kube-news/api/post -H "Content-Type: application/json" \
    -d "{\"artigos\":[{\"title\":\"smoke test\",\"resumo\":\"r\",\"description\":\"d\"}]}" \
    -o /dev/null -w "POST /api/post  HTTP %{http_code}\n"
'
```

O `POST` é o que realmente prova o deploy: ele exercita o caminho aplicação → Service do Postgres → banco. Um `GET /health` passando só prova que o processo Node está de pé.

> **Cuidado com falso negativo aqui.** O `kubectl run -i` às vezes perde o attach e cai para streaming de logs (`warning: couldn't attach to pod, falling back to streaming logs`). Quando isso acontece a saída sai **duplicada e fora de ordem**, e um `grep -c` no meio do pipe pode retornar `0` para um dado que está no banco. Confirme no banco antes de acreditar num resultado negativo — ver [Problema 6](#problema-6--smoke-test-reporta-falha-mas-o-dado-está-no-banco).

### 4. Conferir o dado direto no banco

```bash
PG=$(kubectl get pods -n kube-news -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec $PG -n kube-news -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT id, title FROM \"Posts\" ORDER BY id;"'
```

Esta é a fonte da verdade. Quando o teste HTTP e o banco discordam, o banco está certo.

---

## Problemas conhecidos

### Problema 1 — `exec format error` no pod

**Sintoma:** pod em `CrashLoopBackOff`. Log do container: `exec /usr/local/bin/docker-entrypoint.sh: exec format error` ou equivalente.

**Causa:** a imagem foi buildada em arm64 (Apple Silicon) e os nodes são amd64. Nada nas etapas anteriores reclama — build, push e apply funcionam normalmente. O erro só aparece quando o kernel do node tenta executar o binário.

**Diagnóstico:**

```bash
docker image inspect fabricioveronez/kube-news:v1 --format '{{.Architecture}}'   # arm64 = errado
kubectl get nodes -o custom-columns='NODE:.metadata.name,ARCH:.status.nodeInfo.architecture'
```

**Correção:**

```bash
docker build --platform linux/amd64 -t fabricioveronez/kube-news:v1 .
docker push fabricioveronez/kube-news:v1
kubectl rollout restart deployment/kube-news -n kube-news
```

**Prevenção:** conferir `docker image inspect ... --format '{{.Architecture}}'` antes de todo push. Custa um segundo e evita um debug que começa três passos depois da causa.

---

### Problema 2 — Pods em CrashLoopBackOff / `RESTARTS` subindo no primeiro apply

**Sintoma observado neste deploy:** os dois pods da aplicação chegaram a `Running`/`Ready`, mas com `RESTARTS: 2` cada um. O evento no namespace mostrava `Startup probe failed: dial tcp 10.0.48.181:8080: connect: connection refused` seguido de `BackOff restarting failed container web`.

**Causa:** a aplicação executa `sequelize.sync({alter: true})` no boot (`src/models/post.js:59`) e **sai com exit code 1** se o banco não aceitar conexão. Log do container anterior:

```
Error: connect ECONNREFUSED 172.20.121.227:5432
    errno: -111, code: 'ECONNREFUSED', syscall: 'connect', port: 5432
```

O Postgres e a aplicação sobem em paralelo; a aplicação chega primeiro, não encontra o banco e morre. O Kubernetes reinicia, e por volta da terceira tentativa o banco já está pronto — o deploy "se resolve sozinho", mascarando o problema.

**Por que o `startupProbe` não resolveu isto:**

> `startupProbe` cobre boot **lento**. Não cobre boot que **morre**.
>
> A probe só roda contra um container vivo. Um processo que faz `exit 1` termina antes de qualquer probe ter o que consultar — o kubelet vê um container terminado, não um container demorado, e a resposta dele é reiniciar.

**Correção:** um `initContainer` que segura o start do container principal até o banco responder. Já está no manifesto:

```yaml
initContainers:
  - name: wait-postgres
    image: postgres:16-alpine     # pg_isready já vem na imagem
    command:
      - sh
      - -c
      - until pg_isready -h "$DB_HOST" -p "$DB_PORT"; do sleep 2; done
    envFrom:
      - configMapRef:
          name: kube-news-config  # DB_HOST e DB_PORT sem literal
    resources:                    # init disputa o mesmo nó: recurso declarado
      requests: { cpu: 10m, memory: 32Mi }
      limits:   { cpu: 50m, memory: 32Mi }
```

**Resultado após a correção:** `RESTARTS: 0` nos dois pods.

**Regra derivada:** boot lento → `startupProbe`. Boot que morre por dependência ausente → `initContainer`. As duas ferramentas resolvem problemas diferentes e não se substituem.

---

### Problema 3 — Dados do banco somem

**Sintoma:** posts criados desaparecem depois de um restart, rollout ou reagendamento do pod do Postgres.

**Causa:** decisão de projeto, não defeito — **o Postgres não usa volume**. Os dados vivem na camada gravável do container e morrem com ele.

**Comportamento observado:** ao deletar o pod do Postgres, o banco voltou vazio; a aplicação caiu uma vez (ver [Problema 4](#problema-4--a-aplicação-cai-quando-o-banco-é-recriado)), reiniciou, o `sequelize.sync` recriou a tabela `Posts` — e os dados anteriores não existiam mais.

**Isso é aceitável para lab/imersão e inaceitável para qualquer outra coisa.** Para persistir, o Postgres precisa deixar de ser `Deployment` e virar `StatefulSet` com `volumeClaimTemplates`, ou ganhar um PVC — e nesse caso um banco gerenciado (RDS) costuma ser a resposta melhor do que rodar Postgres no cluster.

**Mitigação já no manifesto:** `strategy: Recreate` no Deployment do Postgres. Com `RollingUpdate`, o rollout subiria um segundo pod com banco vazio enquanto o antigo ainda atende — dois bancos com dados diferentes atrás do mesmo Service, e requisições caindo ora em um, ora no outro. `Recreate` derruba o antigo antes de subir o novo.

---

### Problema 4 — A aplicação cai quando o banco é recriado

**Sintoma:** ao deletar o pod do Postgres, os pods da aplicação foram de `RESTARTS: 0` para `RESTARTS: 1`, e durante ~1 minuto o HTTP respondeu `000` (sem resposta).

**Causa:** comportamento do código da aplicação, não do manifesto. A conexão do Sequelize morre junto com o banco e o processo termina. O Kubernetes reinicia, o `sequelize.sync` roda de novo e recria o schema.

**O que aconteceu certo aqui — e é importante notar:** a liveness probe **não** reiniciou a frota. O `/health` responde apenas pelo processo e não toca no banco, exatamente como projetado. O restart veio do processo morrendo sozinho.

> Se a liveness batesse no banco, um Postgres lento por dois minutos reiniciaria **todos** os pods ao mesmo tempo — e os restarts em cascata piorariam a carga sobre o banco já em apuros. É por isso que liveness nunca checa dependência externa.

**Correção:** nenhuma no manifesto. Resolver de verdade exige tratamento de erro e retry de conexão no código da aplicação. Documentado aqui como comportamento esperado para não ser diagnosticado como problema de cluster.

---

### Problema 5 — `EXTERNAL-IP` fica em `<pending>` ou o LoadBalancer não responde

**Sintoma A — `<pending>` que não sai:**

```
kube-news   LoadBalancer   172.20.12.244   <pending>   80:32157/TCP
```

**Diagnóstico:**

```bash
kubectl describe svc kube-news -n kube-news | sed -n '/Events:/,$p'
```

`Ensuring load balancer` sem o `Ensured load balancer` correspondente indica falha de descoberta de subnet. As subnets públicas precisam da tag `kubernetes.io/role/elb = 1`:

```bash
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=kube-news-dev" --query 'Vpcs[0].VpcId' --output text)
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,ELB:Tags[?Key==`kubernetes.io/role/elb`]|[0].Value}' --output table
```

Neste cluster a tag já vem do Terraform (`terraform/modules/network/main.tf`) e o provisionamento funcionou. A tag `kubernetes.io/cluster/kube-news-dev` **não** foi necessária.

**Sintoma B — `EXTERNAL-IP` preenchido mas `curl` retorna `HTTP 000`:**

Este é o caso mais comum, e **não é erro**. Medição real deste deploy: **~170 segundos** entre o `EXTERNAL-IP` aparecer e o primeiro `HTTP 200`.

O evento `EnsuredLoadBalancer` sai em segundos, mas depois disso o NLB ainda passa por `provisioning` e os targets ficam em `initial` até os health checks passarem. Acompanhe o estado real:

```bash
LB=$(kubectl get svc kube-news -n kube-news -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
NAME=$(echo $LB | cut -d- -f1)
ARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(DNSName,'$NAME')].LoadBalancerArn" --output text)
aws elbv2 describe-load-balancers --load-balancer-arns "$ARN" --query 'LoadBalancers[0].State.Code'
TG=$(aws elbv2 describe-target-groups --load-balancer-arn "$ARN" --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State}' --output table
```

`State: initial` significa "espere". `State: healthy` significa que já deveria responder.

**Regra derivada:** `EXTERNAL-IP` preenchido não significa "pronto". Não diagnostique configuração antes de dar ~3 minutos ao LB.

---

### Problema 6 — Smoke test reporta falha, mas o dado está no banco

**Sintoma:** um `curl ... | grep -c "titulo"` dentro de `kubectl run -i` retornou `0`, sugerindo que a escrita não funcionou — enquanto o `POST` tinha retornado `HTTP 200`.

**Causa:** o `kubectl run -i` perdeu o attach e caiu para streaming de logs:

```
warning: couldn't attach to pod/smoke, falling back to streaming logs:
unable to upgrade connection: container smoke not found in pod smoke
```

Quando isso acontece, a saída sai duplicada e fora de ordem. O `0` era ruído da ferramenta de teste, não resultado da aplicação — a consulta direta no Postgres mostrou o registro presente, e a página HTML renderizava o título normalmente.

**Correção:** ao ver um resultado negativo em smoke test, confirme na fonte da verdade antes de investigar a aplicação:

```bash
PG=$(kubectl get pods -n kube-news -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec $PG -n kube-news -- sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT id, title FROM \"Posts\";"'
```

**Regra derivada:** a ferramenta de teste também falha. Um resultado negativo isolado, sem erro correspondente no log da aplicação, merece uma segunda medição por outro caminho antes de virar investigação.

---

### Problema 7 — ConfigMap alterado e a aplicação continua com o valor antigo

**Sintoma:** `kubectl get configmap kube-news-config -o yaml` mostra o valor novo, mas a aplicação segue usando o antigo. Nenhum erro em lugar nenhum.

**Causa:** variável injetada por `env`/`envFrom` é lida **uma vez**, no start do container. Alterar um ConfigMap ou Secret **não reinicia pod nenhum**.

**Correção adotada no manifesto:** a annotation `checksum/config` no pod template. Mudou a config → muda o checksum → muda o template → o Deployment faz rollout sozinho.

**Isto exige uma ação manual: recalcular o checksum sempre que editar o bloco de config.**

```bash
awk '/^# >>> config-hash-inicio/,/^# <<< config-hash-fim/' k8s/kube-news.yaml | shasum -a 256
```

Substitua o valor nas **duas** annotations `checksum/config` do arquivo (uma no Deployment do Postgres, outra no da aplicação) antes do apply.

**Saída de emergência**, se o checksum ficou desatualizado e a config já foi aplicada:

```bash
kubectl rollout restart deployment/kube-news -n kube-news
```

---

### Problema 8 — `docker push` falha com `unauthorized`

**Sintoma:** `denied: requested access to the resource is denied` ou `unauthorized: authentication required`.

**Correção:**

```bash
docker login
docker push fabricioveronez/kube-news:v1
```

O login é interativo e não pode ser automatizado num runbook. Se estiver rodando em pipeline, use um token de acesso do Docker Hub em vez da senha da conta.

---

## Operações do dia a dia

### Publicar uma versão nova

Nunca reaproveite a tag. Tag nova por release:

```bash
TAG=v2
docker build --platform linux/amd64 -t fabricioveronez/kube-news:$TAG .
docker image inspect fabricioveronez/kube-news:$TAG --format '{{.Architecture}}'   # amd64
docker push fabricioveronez/kube-news:$TAG

# Atualize a imagem E a label de versão no manifesto (k8s/kube-news.yaml):
#   image: fabricioveronez/kube-news:v2
#   app.kubernetes.io/version: "v2"   (em metadata.labels e template.metadata.labels)
# A label de version NÃO entra no selector — selector é imutável.

export DB_PASSWORD='...'
sed "s|<DB_PASSWORD>|${DB_PASSWORD}|" k8s/kube-news.yaml | kubectl apply -f -
kubectl rollout status deployment/kube-news -n kube-news
```

### Ver logs

```bash
# Container atual
kubectl logs -n kube-news -l app.kubernetes.io/name=kube-news --tail=50 -f

# Container ANTERIOR — obrigatório para diagnosticar restart
kubectl logs <pod> -n kube-news --previous --tail=30

# Motivo e exit code do último término
kubectl get pod <pod> -n kube-news \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{" exitCode="}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
```

> `kubectl logs` sem `--previous` mostra o container que está vivo agora. Num CrashLoopBackOff, esse não é o que falhou — o que falhou é o anterior. Esse detalhe é a diferença entre ver o `ECONNREFUSED` e não ver nada de útil.

### Eventos do namespace

```bash
kubectl get events -n kube-news --sort-by=.lastTimestamp | tail -20
```

Primeiro lugar a olhar quando algo não sobe. Mostra falha de pull, probe falhando, backoff e agendamento.

### Acesso à aplicação

```bash
# Externo (Service tipo LoadBalancer)
kubectl get svc kube-news -n kube-news -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Interno, sem depender do LB
kubectl port-forward -n kube-news svc/kube-news 8080:80
# → http://localhost:8080
```

O `port-forward` é o caminho para testar sem esperar o LB, e a forma de validar a aplicação mesmo com o LB quebrado.

---

## Rollback e teardown

### Rollback de uma versão

```bash
kubectl rollout history deployment/kube-news -n kube-news
kubectl rollout undo deployment/kube-news -n kube-news
kubectl rollout status deployment/kube-news -n kube-news
```

> `rollout undo` restaura o spec anterior. Isso só funciona porque as imagens usam **tag fixa**. Com `latest`, o spec anterior também diria `latest` e apontaria para a mesma imagem quebrada — o rollback não teria para onde voltar.

### Derrubar o Load Balancer (parar o custo)

O NLB internet-facing cobra por hora, 24/7, independente de tráfego. Se o cluster for ficar parado:

```bash
kubectl delete svc kube-news -n kube-news       # remove o NLB junto
```

Ou reverta o `type` para `ClusterIP` no manifesto e reaplique — a aplicação continua acessível por `port-forward`.

### Remover tudo

```bash
kubectl delete namespace kube-news
```

Remove os 7 objetos e o NLB. **Não** remove a imagem do Docker Hub nem o cluster.

---

## Lições

O que este deploy ensinou, na ordem em que doeu:

**1. O erro aparece longe da causa.** A imagem arm64 passa por build, push e apply sem uma reclamação, e falha no kernel do node. A validação certa (`docker image inspect --format '{{.Architecture}}'`) custa um segundo e fica três passos antes do sintoma.

**2. `Running` não é `funcionando`.** Os pods estavam `Running` e `Ready` com dois restarts silenciosos cada. A coluna `RESTARTS` é parte da verificação, não um detalhe cosmético.

**3. Probe não conserta processo que morre.** `startupProbe` cobre boot lento; um processo que faz `exit 1` termina antes de a probe ter o que consultar. Dependência ausente no boot é trabalho de `initContainer`.

**4. Separar liveness de readiness tem consequência prática, não estética.** Quando o Postgres foi deletado, a frota **não** reiniciou por causa da probe — porque `/health` não toca no banco. Uma liveness que checasse o banco teria transformado uma queda de dependência em restart em cascata.

**5. As falhas silenciosas são as caras.** Selector desalinhado dá `apply` com sucesso e zero endpoints. ConfigMap alterado sem rollout mostra o valor novo no `kubectl get` e o antigo na aplicação. Nenhum dos dois gera erro — os dois precisam de verificação ativa.

**6. Espere antes de diagnosticar infraestrutura de nuvem.** `EXTERNAL-IP` preenchido não é "pronto": foram ~170s até o primeiro `HTTP 200`. Debugar configuração nesse intervalo é debugar um problema que não existe.

**7. A ferramenta de teste também mente.** Um `grep -c` retornou `0` para um dado que estava no banco, por causa de um fallback de streaming do `kubectl run -i`. Resultado negativo sem erro correspondente no log merece uma segunda medição por outro caminho.

**8. Decisão consciente ≠ decisão sem custo.** O banco sem volume foi escolha explícita e correta para o contexto — e ainda assim exigiu `strategy: Recreate` para não gerar dois bancos divergentes durante um rollout. Toda simplificação deliberada carrega uma consequência que precisa ser tratada em algum lugar.
