# Manifesto de Referência

Conjunto completo e comentado, e o mapa de antipadrão → correção.

- [Conjunto canônico](#conjunto-canônico) — Namespace, ConfigMap, Secret, Deployment, Service
- [Antipadrões](#antipadrões) — o erro, o porquê, a correção

O exemplo usa o `kube-news` deste repositório, com os fatos tirados do código: porta `8080` hardcoded em `src/server.js`, os endpoints `GET /health` e `GET /ready` em `src/system-life.js` (que têm semântica genuinamente diferente), e as variáveis `DB_*` lidas em `src/models/post.js`. Ao adaptar para outra aplicação, refaça essa leitura — os valores abaixo são de um contrato específico, não um template universal.

---

## Conjunto canônico

### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kube-news
  labels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
    app.kubernetes.io/part-of: kube-news
    app.kubernetes.io/managed-by: kubectl
```

O namespace é por aplicação; o ambiente vive no `instance`. Ele entra na entrega sempre que ainda não existir — manifesto que assume namespace pronto falha no `apply` por um motivo que não é o dele.

### ConfigMap — configuração não-sensível

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-news-config
  namespace: kube-news
  labels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
    app.kubernetes.io/component: web
    app.kubernetes.io/part-of: kube-news
    app.kubernetes.io/managed-by: kubectl
data:
  # Chaves e defaults conferidos em src/models/post.js — não inventar variável
  DB_HOST: postgres.kube-news.svc.cluster.local
  DB_PORT: "5432"          # aspas: todo valor de ConfigMap é string
  DB_DATABASE: kubedevnews
  DB_SSL_REQUIRE: "false"  # o código compara com a string 'true'
```

### Secret — credencial

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: kube-news-db
  namespace: kube-news
  labels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
    app.kubernetes.io/component: web
    app.kubernetes.io/part-of: kube-news
    app.kubernetes.io/managed-by: kubectl
type: Opaque
stringData:
  DB_USERNAME: kubedevnews
  # Valor real NÃO vai versionado — Secret é base64, não criptografia.
  # Aqui fica o placeholder; o valor vem do gerenciador de secrets no apply.
  # Se um valor literal precisar aparecer, o '#' exige aspas: "Pg#123"
  DB_PASSWORD: "<DB_PASSWORD>"
```

`stringData` aceita texto puro e o Kubernetes codifica — mais legível que `data` com base64 escrito à mão, e igualmente sem proteção nenhuma.

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-news
  namespace: kube-news                          # regra 6 — explícito, nunca do contexto
  labels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
    app.kubernetes.io/component: web
    app.kubernetes.io/part-of: kube-news
    app.kubernetes.io/managed-by: kubectl
    app.kubernetes.io/version: "1.4.2"          # varia com o release → fora do selector
spec:
  replicas: 2
  selector:
    matchLabels:                                # regra 6 — imutável: só name + instance
      app.kubernetes.io/name: kube-news
      app.kubernetes.io/instance: kube-news-dev
  template:
    metadata:
      labels:                                   # superconjunto do selector
        app.kubernetes.io/name: kube-news
        app.kubernetes.io/instance: kube-news-dev
        app.kubernetes.io/component: web
        app.kubernetes.io/part-of: kube-news
        app.kubernetes.io/managed-by: kubectl
        app.kubernetes.io/version: "1.4.2"
      annotations:
        # regra 3 — muda a config, muda o template, o Deployment faz rollout sozinho.
        # Sem isto, ConfigMap alterado não chega nos pods e nada avisa.
        checksum/config: "<sha256 do configmap.yaml + secret.yaml>"
    spec:
      containers:
        - name: web
          # regra 4 — tag imutável do build. Nunca latest, prod, main ou stable
          image: registry.exemplo.io/kube-news:1.4.2
          imagePullPolicy: IfNotPresent          # coerente com tag fixa
          ports:
            - name: http                         # regra 5 — o Service aponta para o nome
              containerPort: 8080                # src/server.js: app.listen(8080)
              protocol: TCP
          # regra 3 — nada de env.value literal
          envFrom:
            - configMapRef:
                name: kube-news-config
          env:
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: kube-news-db
                  key: DB_USERNAME
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: kube-news-db
                  key: DB_PASSWORD
          # regra 1 — memória travada (não compressível), CPU com folga deliberada.
          # Números de partida: ajustar com consumo observado.
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 256Mi
          # regra 2 — três probes, três propósitos
          startupProbe:
            # A app roda sequelize.sync({alter:true}) no boot (src/models/post.js):
            # o start espera o banco. É isso que a startup cobre.
            httpGet: { path: /health, port: http }
            periodSeconds: 5
            failureThreshold: 30                 # até ~150s de boot
          livenessProbe:
            # /health responde só pelo processo — não toca no banco
            httpGet: { path: /health, port: http }
            periodSeconds: 20
            timeoutSeconds: 3
            failureThreshold: 3                  # tolerante: matar o pod é caro
          readinessProbe:
            # /ready é um endpoint distinto, com semântica de prontidão
            httpGet: { path: /ready, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 2                  # agressiva: sair do Service é barato
```

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kube-news
  namespace: kube-news
  labels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
    app.kubernetes.io/component: web
    app.kubernetes.io/part-of: kube-news
    app.kubernetes.io/managed-by: kubectl
spec:
  type: ClusterIP                                # regra 5 — a borda é decisão do Ingress
  selector:                                      # casa com as labels do pod template
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
  ports:
    - name: http
      port: 80
      targetPort: http                           # nome, não número
      protocol: TCP
```

Depois do apply, `kubectl get endpoints kube-news -n kube-news` precisa listar um IP por pod pronto. Lista vazia é selector desalinhado — e não gera erro nenhum no `apply`.

---

## Antipadrões

### Container sem `resources`

```yaml
# ✗ Errado — QoS BestEffort: primeiro da fila de despejo, e nada contém um vazamento
containers:
  - name: web
    image: registry.exemplo.io/kube-news:1.4.2

# ✓ Certo
    resources:
      requests: { cpu: 100m, memory: 256Mi }
      limits:   { cpu: 500m, memory: 256Mi }
```

### `limits` sem `requests`

```yaml
# ✗ Errado — o scheduler enxerga custo zero e empilha carga no nó
resources:
  limits: { cpu: 500m, memory: 512Mi }

# ✓ Certo — request é o que reserva; memória igual ao limite
resources:
  requests: { cpu: 100m, memory: 512Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

### Folga entre request e limit de memória

```yaml
# ✗ Errado — memória não é compressível: a folga é promessa que o nó não cumpre,
#            e o desfecho é OOMKill em vez de throttle
resources:
  requests: { memory: 128Mi }
  limits:   { memory: 1Gi }

# ✓ Certo — memória travada; a folga, se houver, fica na CPU
resources:
  requests: { cpu: 100m, memory: 512Mi }
  limits:   { cpu: 500m, memory: 512Mi }
```

### `initContainer` sem recurso

```yaml
# ✗ Errado — o init disputa o mesmo nó e derruba a QoS do pod inteiro para BestEffort
initContainers:
  - name: wait-db
    image: busybox:1.36

# ✓ Certo
initContainers:
  - name: wait-db
    image: busybox:1.36
    resources:
      requests: { cpu: 10m, memory: 16Mi }
      limits:   { cpu: 50m, memory: 16Mi }
```

### As duas probes no mesmo endpoint

```yaml
# ✗ Errado — a distinção entre "travou" e "pronto" deixou de existir
livenessProbe:
  httpGet: { path: /health, port: http }
readinessProbe:
  httpGet: { path: /health, port: http }

# ✓ Certo — endpoints distintos, thresholds proporcionais à consequência
livenessProbe:
  httpGet: { path: /health, port: http }
  periodSeconds: 20
  failureThreshold: 3
readinessProbe:
  httpGet: { path: /ready, port: http }
  periodSeconds: 5
  failureThreshold: 2
```

### Liveness checando dependência externa

```yaml
# ✗ Errado — banco lento por dois minutos reinicia a frota inteira,
#            e os restarts pioram a carga sobre o banco já em apuros
livenessProbe:
  httpGet: { path: /health/db, port: http }

# ✓ Certo — dependência é assunto da readiness: sair do Service é reversível
livenessProbe:
  httpGet: { path: /health, port: http }       # só o processo
readinessProbe:
  httpGet: { path: /ready, port: http }        # reflete o banco
```

### `initialDelaySeconds` inflado para cobrir boot lento

```yaml
# ✗ Errado — cobre o boot ao custo de deixar o pod sem detecção de travamento
#            durante 120s, em todo restart, para sempre
livenessProbe:
  httpGet: { path: /health, port: http }
  initialDelaySeconds: 120

# ✓ Certo — a startupProbe segura as outras e depois sai de cena
startupProbe:
  httpGet: { path: /health, port: http }
  periodSeconds: 5
  failureThreshold: 30
livenessProbe:
  httpGet: { path: /health, port: http }
  periodSeconds: 20
```

### `env` com `value` literal

```yaml
# ✗ Errado — config cravada no workload: o Deployment diverge entre ambientes,
#            e a senha está em texto puro no repositório
env:
  - name: DB_HOST
    value: postgres.interno
  - name: DB_PASSWORD
    value: "Pg#123"

# ✓ Certo
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

### ConfigMap alterado sem rollout

```yaml
# ✗ Errado — kubectl apply no ConfigMap não reinicia pod nenhum.
#            O objeto mostra o valor novo, a aplicação segue com o antigo,
#            e não há erro em lugar nenhum.
spec:
  template:
    metadata:
      labels: { ... }

# ✓ Certo — a config entra no template, então mudar a config dispara o rollout
spec:
  template:
    metadata:
      labels: { ... }
      annotations:
        checksum/config: "<sha256 dos manifestos de config>"
```

### Tag móvel

```yaml
# ✗ Errado — pods do mesmo Deployment podem rodar código diferente,
#            e o rollout undo volta para um spec que também diz "latest"
image: kube-news:latest
imagePullPolicy: Always

# ✗ Errado — mesmo defeito, só que menos óbvio
image: registry.exemplo.io/kube-news:prod

# ✓ Certo
image: registry.exemplo.io/kube-news:1.4.2
imagePullPolicy: IfNotPresent

# ✓ Certo — quando a imutabilidade precisa ser garantida, não convencionada
image: registry.exemplo.io/kube-news@sha256:3f0a...c91d
```

### `LoadBalancer` em serviço interno

```yaml
# ✗ Errado — provisiona um balanceador de verdade na cloud, com IP público
#            e fatura, para tráfego que nunca sai do cluster
spec:
  type: LoadBalancer

# ✓ Certo — ClusterIP; a borda é decisão do Ingress, não de cada Service
spec:
  type: ClusterIP
```

### `targetPort` numérico

```yaml
# ✗ Errado — a porta do container passa a existir em dois lugares
ports:
  - port: 80
    targetPort: 8080

# ✓ Certo — o nome sobrevive à mudança da porta real
ports:
  - name: http
    port: 80
    targetPort: http
```

### `selector` do Service desalinhado

```yaml
# ✗ Errado — o pod tem labels app.kubernetes.io/*, o Service procura "app".
#            Resultado: zero endpoints, apply com sucesso, requisição que não chega.
spec:
  selector:
    app: kube-news

# ✓ Certo — as mesmas chaves do template.metadata.labels
spec:
  selector:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
```

Diagnóstico: `kubectl get endpoints <service> -n <ns>` vazio.

### Label variável dentro do `selector`

```yaml
# ✗ Errado — selector é imutável; com "version" ali, o próximo release
#            exige deletar e recriar o Deployment
selector:
  matchLabels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
    app.kubernetes.io/version: "1.4.2"

# ✓ Certo — só o que identifica a instância; version fica no metadata e no template
selector:
  matchLabels:
    app.kubernetes.io/name: kube-news
    app.kubernetes.io/instance: kube-news-dev
```

### Namespace implícito

```yaml
# ✗ Errado — o destino depende do contexto de quem roda o kubectl.
#            O dia em que o contexto estiver em produção não vai ter aviso.
metadata:
  name: kube-news

# ✓ Certo
metadata:
  name: kube-news
  namespace: kube-news
```

### Label fora do padrão

```yaml
# ✗ Errado — cada manifesto com sua convenção quebra o kubectl get -l
#            que deveria trazer a aplicação inteira
labels:
  app: kube-news
  time: plataforma
  ambiente: dev

# ✓ Certo — o conjunto do padrão, em todos os objetos
labels:
  app.kubernetes.io/name: kube-news
  app.kubernetes.io/instance: kube-news-dev
  app.kubernetes.io/component: web
  app.kubernetes.io/part-of: kube-news
  app.kubernetes.io/managed-by: kubectl
```
