---
name: manifestos-kubernetes
description: >
  Escreve manifestos Kubernetes no padrão da operação, seguindo seis regras inegociáveis: requests e
  limits sempre declarados, liveness e readiness separadas com propósitos diferentes, variáveis de
  ambiente sempre via ConfigMap ou Secret, imagem sempre com tag fixada, Service coerente com a
  exposição pretendida, e labels e namespace no padrão do time. Use sempre que o usuário disser "cria o
  deployment", "escreve o manifesto", "monta o service", "preciso subir isso no Kubernetes", "cria o
  YAML do k8s", "coloca essa aplicação no cluster", "cria o configmap", "revisa esses manifestos", ou
  apontar arquivos YAML de Kubernetes querendo criá-los ou mudá-los. Ative também quando o pedido
  parecer pequeno — "só um deployment rapidinho", "só ajusta a porta do service" — porque é exatamente
  no manifesto avulso que o recurso não declarado e a tag latest entram; e quando for revisar manifesto
  que já existe no projeto. NÃO acione para: Dockerfile, docker-compose e build de imagem (isso é
  containerizar-aplicacao), Terraform e provisionamento de cluster (isso é terraform-boas-praticas),
  Helm charts e Kustomize, pipelines de CI/CD, e debug de aplicação que já está rodando no cluster
  (pod em CrashLoopBackOff, investigação de log, problema de rede do cluster).
---

# Manifestos Kubernetes

Manifesto ruim quase nunca é YAML inválido. O `kubectl apply` aceita sem reclamar um Deployment sem recurso declarado, com as duas probes apontando para o mesmo endpoint, com a senha do banco em texto puro, rodando `latest`, exposto por um LoadBalancer que ninguém pediu. Tudo isso sobe, fica `Running`, e o problema aparece semanas depois — no nó que despejou o pod errado sob pressão, no restart em cascata quando o banco ficou lento, no rollback que não tinha para onde voltar.

As seis regras abaixo existem para tornar esses erros difíceis de cometer. Elas valem para qualquer aplicação e qualquer cluster.

## As seis regras

| Regra | O que isso descarta na prática |
|---|---|
| **1. Requests e limits sempre declarados** | container sem bloco `resources`, `limits` sem `requests`, QoS `BestEffort` por esquecimento |
| **2. Liveness e readiness separadas** | as duas probes no mesmo endpoint, liveness checando banco, `initialDelaySeconds` inflado para disfarçar boot lento |
| **3. Env via ConfigMap ou Secret** | `env: [{name: DB_HOST, value: postgres}]` no Deployment, senha em texto puro no YAML versionado |
| **4. Imagem com tag fixada** | `image: app:latest`, `app:prod`, `app:main`, `imagePullPolicy: Always` para compensar tag móvel |
| **5. Service coerente com a exposição** | `LoadBalancer` em serviço interno, `NodePort` fora de lab, `targetPort` numérico duplicando a porta |
| **6. Labels e namespace no padrão** | objeto sem `namespace` explícito, label inventada por manifesto, selector com label demais |

Quando o pedido do usuário conflitar com uma delas (por exemplo: "deixa sem limit que é só dev" ou "usa latest mesmo"), não execute em silêncio nem recuse: diga em uma frase o que a regra manda e por quê, entregue seguindo a regra, e deixe claro o que foi feito diferente do pedido. Se o usuário reafirmar, é decisão dele — siga.

## Quando aprofundar

| Situação | Onde ir |
|---|---|
| Vai escrever manifestos do zero e quer o conjunto completo (Namespace, ConfigMap, Secret, Deployment, Service) para copiar | `references/manifesto-de-referencia.md` |
| Está revisando manifesto existente e quer o mapa de antipadrão → correção | `references/manifesto-de-referencia.md`, seção **Antipadrões** |

> **Antes de escrever, descubra o contrato.** Porta de escuta, endpoints de health, variáveis de ambiente e seus defaults saem do código da aplicação, não de suposição. Manifesto com `/healthz` numa app que só expõe `/health`, ou com uma variável `PORT` que ninguém lê, é configuração decorativa: parece certa e evapora no primeiro debug.

---

## Regra 1 — Requests e limits sempre declarados

Todo container carrega `resources` com `requests` e `limits` de CPU e memória. Isso inclui `initContainers` e sidecars — eles disputam o mesmo nó.

`requests` é o que o scheduler reserva; `limits` é o teto que o kubelet impõe. Sem `requests`, o scheduler enxerga o pod como custo zero e empilha carga no nó até ele saturar. Sem `limits`, um vazamento de memória em um pod derruba vizinhos que não têm nada a ver com o problema.

### O que a ausência custa: QoS

A classe de QoS não é declarada — o Kubernetes deriva dela do que você escreveu, e ela decide quem morre primeiro quando o nó fica sem memória:

| Classe | Como se obtém | Sob pressão de memória |
|---|---|---|
| `Guaranteed` | `requests == limits` para CPU **e** memória, em todos os containers | despejado por último |
| `Burstable` | tem `requests`, mas não bate com `limits` | despejado depois do BestEffort, na ordem do excesso sobre o request |
| `BestEffort` | nenhum `resources` declarado | **primeiro da fila de despejo** |

Omitir `resources` não é adiar a decisão — é escolher `BestEffort`.

### CPU e memória se comportam de forma diferente

Memória é um recurso **não compressível**: passar do limite não desacelera o processo, mata ele com OOMKill. Por isso `requests.memory` e `limits.memory` devem ser iguais — a folga entre os dois é uma promessa que o nó não tem como cumprir na hora do aperto.

CPU é **compressível**: passar do limite gera throttling, não morte. Isso torna o limite de CPU uma decisão consciente sobre latência, não algo a omitir por esquecimento. Declare o limite; se o serviço for sensível a latência de cauda e você decidir dar folga, deixe a folga entre `requests` e `limits` explícita.

```yaml
# Ruim — BestEffort, primeiro a ser despejado, e nada impede o vazamento
containers:
  - name: web
    image: registry.exemplo.io/kube-news:1.4.2

# Ruim — limit sem request: o scheduler não reserva nada
resources:
  limits:
    memory: 512Mi

# Bom — memória travada (não é compressível), CPU com folga deliberada
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

Os números vêm de medição, não de gosto. Sem dado de consumo, comece por uma estimativa da stack, diga que é ponto de partida, e sinalize que o ajuste depende de observar o consumo real — um valor chutado e apresentado como definitivo é pior que um chute assumido.

---

## Regra 2 — Liveness e readiness separadas, com propósitos diferentes

As duas probes existem porque respondem a perguntas distintas e têm consequências distintas. Apontar as duas para o mesmo endpoint apaga a diferença e transforma duas ferramentas em um health check duplicado.

| | Liveness | Readiness |
|---|---|---|
| Pergunta | o processo travou e só restart resolve? | posso receber tráfego agora? |
| Consequência da falha | o container é **morto e reiniciado** | o pod **sai dos endpoints do Service** |
| Reversível? | não — perde estado em memória, conta restart | sim — volta sozinho quando passar |
| Checa dependência externa? | **não** | sim, quando faz sentido |

### Por que liveness não checa dependência

Se a liveness bate no banco, um banco lento por dois minutos reinicia **a frota inteira** ao mesmo tempo. Os pods sobem, tentam conectar no banco que ainda está lento, falham de novo, e o restart vira um loop que só piora a carga sobre a dependência já em apuros. O restart só é a resposta certa quando o problema está **dentro** do processo — deadlock, event loop travado, heap corrompido.

A readiness pode e deve refletir dependência: um pod que não consegue falar com o banco não deveria receber requisição, e sair do Service é barato e reversível.

### Os thresholds seguem a consequência

Readiness pode ser agressiva porque errar custa pouco. Liveness precisa ser tolerante porque errar mata o pod: `failureThreshold` maior e `periodSeconds` mais espaçado, para que um pico de latência não seja confundido com processo travado.

Boot lento se resolve com `startupProbe`, não afrouxando o `initialDelaySeconds` da liveness. A startup segura as outras duas até a aplicação subir, e depois sai de cena — inflar o `initialDelaySeconds` cobre o boot ao custo de deixar o pod travado sem detecção durante todo esse tempo, para sempre.

```yaml
# Ruim — mesmo endpoint nos dois campos: a distinção deixou de existir
livenessProbe:
  httpGet: { path: /health, port: http }
readinessProbe:
  httpGet: { path: /health, port: http }

# Bom — propósitos distintos, thresholds proporcionais à consequência
startupProbe:                              # segura as outras até o boot terminar
  httpGet: { path: /health, port: http }
  periodSeconds: 5
  failureThreshold: 30                     # até 150s de boot
livenessProbe:                             # só o processo — nada de dependência
  httpGet: { path: /health, port: http }
  periodSeconds: 20
  timeoutSeconds: 3
  failureThreshold: 3                      # tolerante: matar é caro
readinessProbe:                            # reflete a dependência
  httpGet: { path: /ready, port: http }
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 2                      # agressiva: sair do Service é barato
```

Quando a aplicação **não** tem endpoints distintos, o achado é esse: reporte que só existe um, use-o na liveness, e diga que a readiness precisa de um endpoint que reflita a prontidão real. Não invente uma rota que o código não serve.

---

## Regra 3 — Variáveis de ambiente via ConfigMap ou Secret

Nenhum `env` com `value` literal no Deployment. Configuração não-sensível vai em ConfigMap; credencial, token e chave vão em Secret — sempre referenciados por `configMapKeyRef` / `secretKeyRef`, ou em bloco por `envFrom`.

O ganho não é estético. Com a configuração fora, o Deployment fica **igual entre ambientes**: o que muda de dev para prod é um objeto de config, não o manifesto da aplicação. E mudar uma variável deixa de exigir editar (e arriscar) o spec do workload.

```yaml
# Ruim — config e credencial cravadas no workload
env:
  - name: DB_HOST
    value: postgres.interno
  - name: DB_PASSWORD
    value: "Pg#123"

# Bom — bloco de config por envFrom, credencial por referência
envFrom:
  - configMapRef:
      name: kube-news-config
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: kube-news-db
        key: DB_PASSWORD
```

Use `envFrom` quando o conjunto inteiro do ConfigMap é para a aplicação; use `valueFrom` chave a chave quando só parte interessa, ou quando o nome da variável no container difere da chave.

### Secret é codificação, não criptografia

`stringData` em base64 é transporte, não proteção — qualquer um com leitura no namespace decodifica. Duas consequências práticas: **o valor real de um Secret não vai para o repositório**, e o manifesto versionado carrega placeholder, com o valor vindo do gerenciador de secrets do time no momento do apply. Se o projeto ainda não tem essa peça, entregue o Secret com placeholder e diga explicitamente que ele não pode ser commitado preenchido.

Atenção ao YAML: valor com `#` precisa de aspas (`"Pg#123"`), senão o resto da linha vira comentário.

### A armadilha do rollout

Alterar um ConfigMap ou Secret **não reinicia os pods**. Variável injetada por `env`/`envFrom` é lida uma vez, no start do container: o objeto muda, o `kubectl get configmap` mostra o valor novo, e a aplicação segue com o antigo — sem erro em lugar nenhum.

Duas saídas: uma annotation de checksum da config no pod template (mudou a config, mudou o template, o Deployment faz rollout sozinho), ou versionar o nome do objeto (`kube-news-config-v3`) e apontar o Deployment para o novo. Escolha uma e seja consistente; não deixe o rollout dependendo de alguém lembrar de rodar `kubectl rollout restart`.

---

## Regra 4 — Imagem sempre com tag fixada

Nunca `latest`. E não só `latest`: **qualquer tag móvel** — `prod`, `stable`, `main`, `dev` — tem o mesmo defeito, porque o conteúdo por trás dela muda sem que o manifesto mude.

Tag móvel quebra três coisas de uma vez:

1. **Os pods de um mesmo Deployment podem rodar código diferente.** Cada pod puxa a imagem no momento em que sobe; um pod recriado depois de um push pega outro conteúdo, e você fica com duas versões atendendo atrás do mesmo Service.
2. **Rollback não tem para onde voltar.** `kubectl rollout undo` restaura o spec anterior — que também dizia `latest`, e portanto aponta para a mesma imagem quebrada.
3. **O manifesto para de descrever o que está rodando.** Não dá para responder "qual versão está em prod?" olhando o YAML.

Use tag imutável derivada do build — SHA do commit, versão semântica, número de build — ou o digest quando a garantia precisa ser criptográfica:

```yaml
# Ruim
image: kube-news:latest
imagePullPolicy: Always      # o "Always" é o sintoma, não a correção

# Bom — tag imutável
image: registry.exemplo.io/kube-news:1.4.2
imagePullPolicy: IfNotPresent

# Bom — digest, quando a imutabilidade precisa ser garantida e não convencionada
image: registry.exemplo.io/kube-news@sha256:3f0a...c91d
```

Sobre o `imagePullPolicy`: com tag fixa, `IfNotPresent` é o correto e evita pull desnecessário a cada start. `Always` só existe para compensar tag móvel — se você sentiu necessidade dele, o problema está na tag.

Quando o registry e a tag ainda não estiverem definidos no projeto, não preencha com `latest` como provisório. Use um placeholder evidente (`registry.exemplo.io/kube-news:<TAG>`) e diga que precisa da tag do build — placeholder óbvio é uma pergunta; `latest` é uma decisão errada disfarçada de rascunho.

---

## Regra 5 — Service coerente com a exposição pretendida

O tipo do Service é uma declaração de quem pode alcançar a aplicação. Escolha pela intenção, não pelo hábito de copiar o manifesto anterior:

| Intenção | Tipo | Sinal de que está errado |
|---|---|---|
| Consumido só por outros pods do cluster | `ClusterIP` (default) | — |
| É de fato borda: recebe tráfego de fora | `LoadBalancer` | um LB (e um IP público, e uma fatura) para um serviço que só o front interno chama |
| Cluster de lab, sem ingress disponível | `NodePort` | NodePort em produção: amarra a porta ao nó e vaza a aplicação em toda a frota |
| Descoberta pod a pod (StatefulSet, cliente com balanceamento próprio) | `clusterIP: None` (headless) | headless em app web comum: o cliente passa a receber todos os IPs e balancear sozinho |

`LoadBalancer` é o erro caro: cada um provisiona um balanceador de verdade na cloud, com custo e superfície pública, e o `type` no YAML é a única evidência de que alguém decidiu isso.

### Dois detalhes que quebram em silêncio

**`targetPort` referenciando porta nomeada.** Nomeie a porta no container e aponte o Service para o nome. Assim a porta real muda em um lugar só, e o Service não fica com um número desatualizado que ninguém percebe.

**`selector` casando com as labels do pod.** Selector que não casa produz um Service com **zero endpoints** — e o `apply` retorna sucesso. Não há erro, não há evento, só requisição que não chega. O selector aponta para as labels do **pod template**, não para as do Deployment.

```yaml
# Ruim — LoadBalancer para serviço interno, porta numérica duplicada,
#        selector que não casa com as labels do pod
spec:
  type: LoadBalancer
  selector:
    app: kube-news
  ports:
    - port: 80
      targetPort: 8080

# Bom
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
  ports:
    - name: http
      port: 80
      targetPort: http        # nome da porta do container
```

Depois do apply, `kubectl get endpoints <service>` vazio é o sintoma exato de selector desalinhado.

---

## Regra 6 — Labels e namespace no padrão do time

Todo objeto carrega o conjunto de labels recomendadas do Kubernetes e um `namespace` explícito. O namespace é **por aplicação**; o ambiente aparece no `instance`.

```yaml
metadata:
  name: kube-news
  namespace: kube-news
  labels:
    app.kubernetes.io/name: kube-news        # a aplicação
    app.kubernetes.io/instance: kube-news-dev # esta instância (aplicação + ambiente)
    app.kubernetes.io/component: web          # o papel: web, worker, db, cache
    app.kubernetes.io/part-of: kube-news      # o sistema maior a que pertence
    app.kubernetes.io/managed-by: kubectl     # quem gerencia o ciclo de vida
```

O conjunto vai em **todos** os objetos — Deployment, Service, ConfigMap, Secret, Namespace. É isso que faz `kubectl get all -l app.kubernetes.io/instance=kube-news-dev` retornar a aplicação inteira, e não uma parte dela.

### O selector é o subconjunto imutável

O `selector.matchLabels` do Deployment usa **apenas** `name` + `instance`:

```yaml
# Ruim — component e version no selector travam o objeto
selector:
  matchLabels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
    app.kubernetes.io/component: web
    app.kubernetes.io/version: 1.4.2

# Bom — o mínimo que identifica esta instância, e que nunca precisa mudar
selector:
  matchLabels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
```

`selector` é imutável depois do apply: mudá-lo exige deletar e recriar o Deployment. Toda label que varia ao longo da vida do objeto — `version` acima de tudo — fica fora dele, no `metadata.labels` e no `template.metadata.labels`, onde pode mudar livremente. As labels do pod template são um superconjunto do selector, nunca o contrário.

### Namespace explícito

`namespace` vai escrito no manifesto, em todos os objetos. Depender do contexto do `kubectl` significa que o mesmo arquivo aplica em lugares diferentes conforme quem roda — e o dia em que o contexto estiver em `default` ou em produção não vai ter aviso nenhum. Quando o namespace ainda não existe, o manifesto do `Namespace` faz parte da entrega.

---

## Antes de entregar

Cada item mapeia direto em uma das seis regras e é verificável olhando o YAML:

- [ ] Todo container — incluindo `initContainers` e sidecars — tem `resources` com `requests` **e** `limits`, e `requests.memory == limits.memory`
- [ ] `livenessProbe` e `readinessProbe` existem e apontam para endpoints **diferentes**, que a aplicação de fato serve
- [ ] A liveness não toca em nenhuma dependência externa, e o boot lento (se houver) está coberto por `startupProbe`
- [ ] Nenhum `env` com `value` literal — tudo por `configMapKeyRef`, `secretKeyRef` ou `envFrom`
- [ ] Nenhum valor real de credencial no YAML versionado, e o rollout ao mudar config está resolvido (checksum ou nome versionado)
- [ ] Nenhuma imagem com `latest` ou tag móvel; `imagePullPolicy` coerente com a tag fixa
- [ ] O `type` do Service corresponde à exposição pretendida, o `targetPort` usa porta nomeada, e o `selector` casa com as labels do pod template
- [ ] Todo objeto tem `namespace` explícito e as cinco labels `app.kubernetes.io/*`
- [ ] O `selector.matchLabels` do Deployment tem só `name` + `instance`

---

## O que esta skill NÃO faz

- Dockerfile, `.dockerignore`, docker-compose e build de imagem — isso é `containerizar-aplicacao`
- Provisionamento de cluster e infraestrutura como código — isso é `terraform-boas-praticas`
- Helm charts, Kustomize e qualquer camada de template sobre o YAML
- Ingress, HPA, PodDisruptionBudget, NetworkPolicy, `securityContext` e hardening
- GitOps, pipeline de deploy, ArgoCD/Flux
- Debug de aplicação já rodando no cluster — CrashLoopBackOff, leitura de log, problema de rede

---

## Anti-patterns

- Container sem bloco `resources` — QoS `BestEffort`, primeiro da fila de despejo, e nada segura um vazamento
- `limits` sem `requests` — o scheduler não reserva nada e o nó fica overcommitado
- `requests.memory` menor que `limits.memory` — a folga é uma promessa que o nó não cumpre; o resultado é OOMKill
- Número de recurso apresentado como definitivo sem nenhuma medição por trás
- Esquecer `resources` no `initContainer` e no sidecar — eles disputam o mesmo nó
- Liveness e readiness no mesmo endpoint — duas ferramentas viram um health check duplicado
- Liveness batendo no banco — dependência lenta reinicia a frota inteira e piora a carga sobre ela
- `initialDelaySeconds` inflado para cobrir boot lento — o pod fica sem detecção de travamento para sempre; é `startupProbe`
- Probe apontando para uma rota que o código não serve — configuração decorativa
- `env` com `value` literal no Deployment — o workload passa a divergir entre ambientes
- Senha em texto puro no YAML versionado — Secret é base64, não criptografia
- Alterar ConfigMap e achar que o pod pegou o valor novo — só rollout recarrega env
- `image: app:latest` — dois pods do mesmo Deployment podem rodar código diferente, e o rollback não tem para onde voltar
- Tag móvel (`prod`, `stable`, `main`) — mesmo defeito do `latest`, só que menos óbvio
- `imagePullPolicy: Always` — é sintoma de tag móvel, não correção
- `latest` como placeholder "provisório" — uma decisão errada disfarçada de rascunho
- `LoadBalancer` em serviço interno — um balanceador de verdade, com IP público e fatura, para tráfego que nunca sai do cluster
- `NodePort` fora de lab — amarra a porta ao nó e expõe a aplicação em toda a frota
- `targetPort` numérico repetindo a porta do container — dois lugares para manter em sincronia
- `selector` do Service que não casa com as labels do pod — zero endpoints, `apply` com sucesso, nenhum erro em lugar nenhum
- `component` ou `version` no `selector.matchLabels` — selector é imutável; mudar exige recriar o Deployment
- Objeto sem `namespace` explícito — o destino passa a depender do contexto de quem roda o `kubectl`
- Label inventada por manifesto — quebra o `kubectl get -l` que deveria trazer a aplicação inteira
