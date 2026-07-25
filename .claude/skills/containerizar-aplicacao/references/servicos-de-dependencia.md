# Serviços de dependência

Blocos de compose prontos para os serviços mais comuns. Três coisas importam em cada um: o **healthcheck que de fato funciona**, as **variáveis de inicialização** (que precisam bater com o contrato da aplicação), e o **caminho do volume** correto.

> **Os defaults abaixo são placeholders, não valores a copiar.** `<default-do-codigo>` significa: use o default que a fase 1 encontrou no código da aplicação. Copiar um default inventado daqui é justamente o anti-pattern de criar um terceiro ambiente que ninguém testou — o banco passa a esperar um usuário que a aplicação nunca vai pedir.
>
> **Cuidado com escaping.** Defaults reais costumam ter caracteres especiais. Em YAML, `#` precisa do valor entre aspas para não virar comentário; na interpolação do Compose, um `$` literal precisa ser escrito `$$`. Uma senha como `Pg#123` vai entre aspas; `pa$$w0rd` vira `pa$$$$w0rd`.

## O healthcheck é o que amarra a ordem de inicialização

`depends_on` sozinho espera o container *iniciar*. Um Postgres leva vários segundos entre o processo subir e o socket aceitar conexão — e uma aplicação que conecta no boot morre nessa janela. O sintoma é o pior tipo: intermitente. Funciona na máquina rápida, falha na lenta, falha no CI.

```yaml
# Ruim — espera o container existir, não o banco responder
depends_on:
  - db

# Bom — espera o healthcheck passar
depends_on:
  db:
    condition: service_healthy
```

O healthcheck precisa ser **local ao serviço**. Um healthcheck que depende de rede externa transforma um incidente lá fora em falha em cascata aqui dentro.

---

## PostgreSQL

```yaml
db:
  image: postgres:16-alpine
  restart: unless-stopped
  environment:
    POSTGRES_DB: ${DB_DATABASE:-<default-do-codigo>}
    POSTGRES_USER: ${DB_USERNAME:-<default-do-codigo>}
    POSTGRES_PASSWORD: ${DB_PASSWORD:-<default-do-codigo>}
  volumes:
    - pgdata:/var/lib/postgresql/data
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U ${DB_USERNAME:-<default-do-codigo>} -d ${DB_DATABASE:-<default-do-codigo>}"]
    interval: 5s
    timeout: 5s
    retries: 12
    start_period: 10s
  ports:
    - "127.0.0.1:5432:5432"
```

- `pg_isready` **sem** `-U` e `-d` testa o usuário default e pode passar antes do banco da aplicação existir. Sempre passe os dois.
- As três variáveis `POSTGRES_*` só têm efeito na **primeira** inicialização do volume. Mudou a senha e não funcionou? O volume antigo ainda tem a senha velha.
- Confirmar de fora: `docker compose exec -T db psql -U <user> -d <db> -c '\dt'`

## MySQL / MariaDB

```yaml
db:
  image: mysql:8.4
  restart: unless-stopped
  environment:
    MYSQL_DATABASE: ${DB_DATABASE:-<default-do-codigo>}
    MYSQL_USER: ${DB_USERNAME:-<default-do-codigo>}
    MYSQL_PASSWORD: ${DB_PASSWORD:-<default-do-codigo>}
    MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD:-<default-do-codigo>}
  volumes:
    - mysqldata:/var/lib/mysql
  healthcheck:
    test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-u", "root", "-p${DB_ROOT_PASSWORD:-<default-do-codigo>}"]
    interval: 5s
    timeout: 5s
    retries: 15
    start_period: 30s
  ports:
    - "127.0.0.1:3306:3306"
```

- MySQL demora bem mais que Postgres para a primeira inicialização — `start_period: 30s` não é exagero.
- `mysqladmin ping` responde "alive" mesmo durante a inicialização, quando o servidor ainda recusa conexões da aplicação. Se a corrida persistir, troque por `mysql -u<user> -p<pass> -e 'SELECT 1'`, que exige autenticação real.
- Confirmar de fora: `docker compose exec -T db mysql -u<user> -p<pass> <db> -e 'SHOW TABLES;'`

## Redis

```yaml
cache:
  image: redis:7-alpine
  restart: unless-stopped
  command: ["redis-server", "--appendonly", "yes"]
  volumes:
    - redisdata:/data
  healthcheck:
    test: ["CMD", "redis-cli", "ping"]
    interval: 5s
    timeout: 3s
    retries: 10
  ports:
    - "127.0.0.1:6379:6379"
```

- Sem `--appendonly yes` (ou snapshot configurado) o Redis não persiste, e o volume não serve para nada. Se o Redis é só cache, isso é aceitável — mas seja explícito sobre a escolha em vez de declarar um volume que não guarda nada.
- Com senha (`--requirepass`), o healthcheck precisa dela: `redis-cli -a <senha> ping`.
- Confirmar de fora: `docker compose exec -T cache redis-cli DBSIZE`

## MongoDB

```yaml
mongo:
  image: mongo:7
  restart: unless-stopped
  environment:
    MONGO_INITDB_ROOT_USERNAME: ${MONGO_USER:-<default-do-codigo>}
    MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD:-<default-do-codigo>}
    MONGO_INITDB_DATABASE: ${MONGO_DATABASE:-<default-do-codigo>}
  volumes:
    - mongodata:/data/db
  healthcheck:
    test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
    interval: 5s
    timeout: 5s
    retries: 12
    start_period: 20s
  ports:
    - "127.0.0.1:27017:27017"
```

- `mongosh` substituiu o `mongo` a partir da versão 6 — o healthcheck com `mongo` falha silenciosamente em imagens novas.
- `MONGO_INITDB_DATABASE` só cria o banco se houver scripts de inicialização; sem isso o Mongo cria o banco na primeira escrita.
- Confirmar de fora: `docker compose exec -T mongo mongosh --quiet --eval 'db.getMongo().getDBNames()'`

## RabbitMQ

```yaml
queue:
  image: rabbitmq:3.13-management-alpine
  restart: unless-stopped
  environment:
    RABBITMQ_DEFAULT_USER: ${RABBITMQ_USER:-<default-do-codigo>}
    RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD:-<default-do-codigo>}
  volumes:
    - rabbitdata:/var/lib/rabbitmq
  healthcheck:
    test: ["CMD", "rabbitmq-diagnostics", "-q", "check_running", "&&", "rabbitmq-diagnostics", "-q", "check_local_alarms"]
    interval: 10s
    timeout: 10s
    retries: 10
    start_period: 30s
  ports:
    - "127.0.0.1:5672:5672"
    - "127.0.0.1:15672:15672"   # UI de management
```

- RabbitMQ é lento para subir — `start_period: 30s` e `interval: 10s`.
- `check_running` sozinho passa antes do broker aceitar publicações; combinar com `check_local_alarms` reduz o falso positivo.
- Confirmar de fora: `docker compose exec -T queue rabbitmqctl list_queues`

---

## Quando o app precisa de mais de um serviço

Encadeie as condições — o compose resolve o grafo:

```yaml
app:
  depends_on:
    db:
      condition: service_healthy
    cache:
      condition: service_healthy
```

Se um dos serviços é um job que roda e termina (migration, seed), a condição é outra:

```yaml
  migrate:
    condition: service_completed_successfully
```

## Worker como segundo serviço

Filas trazem um padrão recorrente: o worker é **a mesma imagem** com outro comando. Reaproveite o build em vez de duplicar:

```yaml
app:
  build: .
  command: ["node", "server.js"]

worker:
  build: .              # mesmo contexto, mesma imagem
  command: ["node", "worker.js"]
  depends_on:
    queue:
      condition: service_healthy
```

O worker não expõe porta, então a validação dele não é HTTP: a prova é publicar uma mensagem de teste e observar o efeito.

## Erros comuns

- **Mudei a senha no compose e a autenticação continua falhando.** As variáveis de inicialização só têm efeito na criação do volume. Ou remova o volume (perdendo os dados), ou altere a senha por dentro do banco.
- **O healthcheck fica `starting` para sempre.** O comando de teste não existe na imagem (`curl` em imagem sem curl, `mongo` em imagem com `mongosh`). Rode o comando manualmente com `exec` para ver o erro.
- **O app conecta em `localhost` e falha.** Dentro do compose, `localhost` é o próprio container. O host é o **nome do serviço** — é a única variável do contrato que muda.
- **Dois projetos brigando pela mesma porta.** Publique serviços internos em `127.0.0.1:<porta>` e deixe a porta variável (`${DB_PORT:-5432}:5432`), ou simplesmente não publique — a aplicação alcança o serviço pela rede do compose sem publicação nenhuma.
