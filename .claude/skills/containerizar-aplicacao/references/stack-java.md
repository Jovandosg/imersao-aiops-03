# Stack Java

## Onde está cada evidência

| Evidência | Onde procurar |
|---|---|
| Versão do runtime | `<java.version>` ou `maven.compiler.release` no `pom.xml`; `java { toolchain { languageVersion } }` no `build.gradle` |
| Build tool | `pom.xml` (Maven) ou `build.gradle`/`build.gradle.kts` (Gradle). Prefira o **wrapper** (`mvnw`, `gradlew`) — a versão está pinada nele |
| Nome do artefato | `<artifactId>` + `<version>`, ou `archiveFileName` no Gradle |
| Porta | `server.port` no `application.properties`/`application.yml`. Ausente em Spring Boot = **8080** |
| Env vars | os placeholders `${DB_HOST:localhost}` no `application.yml` — o valor após os dois-pontos é o default |
| Override por ambiente | o *relaxed binding* do Spring: `SPRING_DATASOURCE_URL`, `SPRING_PROFILES_ACTIVE`, `SERVER_PORT` |
| Serviços de dependência | os drivers: `postgresql`, `mysql-connector-j`, `spring-boot-starter-data-redis`, `-data-mongodb`, `-amqp`, `-kafka` |
| Migration no boot | Flyway ou Liquibase no classpath, ou `spring.jpa.hibernate.ddl-auto` |
| Health | `spring-boot-starter-actuator` → `/actuator/health`, `/actuator/health/readiness` |

O contrato de env em Spring é duplo, e os dois lados importam: os placeholders no `application.yml` dizem **quais** variáveis existem e **com que default**; o relaxed binding diz **como** sobrescrevê-las (`spring.datasource.url` → `SPRING_DATASOURCE_URL`).

## Dependências e cache

Maven e Gradle não têm lockfile por padrão — as versões estão declaradas no próprio manifesto. O que importa para o cache é baixar as dependências antes de copiar o código:

```dockerfile
# Maven
COPY pom.xml ./
RUN ./mvnw dependency:go-offline -B

# Gradle
COPY build.gradle settings.gradle ./
RUN ./gradlew dependencies --no-daemon
```

Use cache mount em `/root/.m2` ou `/root/.gradle` — sem isso o download inteiro repete a cada build sem cache de camada. E sempre `--no-daemon` no Gradle: daemon em container é desperdício de memória e não sobrevive à camada.

## Armadilhas de CWD

Java é a stack com menos armadilhas, porque o padrão do ecossistema é empacotar recursos dentro do jar:

| Padrão | Resolve a partir de | Risco |
|---|---|---|
| `src/main/resources/**` → `classpath:` | dentro do jar | seguro |
| Templates Thymeleaf/Freemarker em `resources/templates` | classpath | seguro |
| `spring.config.location=file:./config/` | CWD | alto |
| `new File("dados.csv")`, `Paths.get("uploads")` | CWD | alto |
| Appender de log com caminho relativo | CWD | médio — sobe e falha ao escrever |

A armadilha real do Java é outra: **o glob do jar**. Um build Gradle produz tanto `app-1.0.jar` quanto `app-1.0-plain.jar`, e um `COPY build/libs/*.jar app.jar` copia os dois ou o errado.

```dockerfile
# Ruim — pega o -plain.jar (sem as dependências) e o container morre com NoClassDefFoundError
COPY --from=build /src/build/libs/*.jar app.jar

# Bom — nomeia o artefato explicitamente no build
RUN ./gradlew bootJar --no-daemon -PjarName=app
COPY --from=build /src/build/libs/app.jar app.jar
```

## Dockerfile — Spring Boot com jar em camadas

O jar em camadas separa dependências (que mudam pouco) do código da aplicação (que muda sempre), transformando um jar monolítico de 50 MB em camadas com cache útil.

```dockerfile
# syntax=docker/dockerfile:1
ARG JDK_VERSION=21

FROM eclipse-temurin:${JDK_VERSION}-jdk-alpine AS build
WORKDIR /src
COPY mvnw pom.xml ./
COPY .mvn .mvn
RUN --mount=type=cache,target=/root/.m2 ./mvnw dependency:go-offline -B
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 ./mvnw clean package -DskipTests -B
# Extrai o jar em camadas para o stage seguinte
RUN java -Djarmode=layertools -jar target/*.jar extract --destination /out

FROM eclipse-temurin:${JDK_VERSION}-jre-alpine AS runtime
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
# Ordem importa: da camada que menos muda para a que mais muda
COPY --from=build --chown=app:app /out/dependencies/ ./
COPY --from=build --chown=app:app /out/spring-boot-loader/ ./
COPY --from=build --chown=app:app /out/snapshot-dependencies/ ./
COPY --from=build --chown=app:app /out/application/ ./
USER app
EXPOSE 8080
# A JVM respeita o limite de memória do cgroup, mas o default de 25% é conservador
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0"
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
```

Para uma versão mais simples, sem camadas, o runtime é só `COPY --from=build /src/target/app.jar app.jar` + `ENTRYPOINT ["java", "-jar", "app.jar"]`.

## Notas

- **Use a imagem `-jre` no runtime, não a `-jdk`.** O JDK carrega compilador e ferramentas que a aplicação não usa — costuma ser mais que o dobro do tamanho.
- **`MaxRAMPercentage`:** a JVM moderna reconhece o limite de memória do container, mas reserva só ~25% do disponível para o heap. Em container dedicado, 75% é um ponto de partida melhor.
- **O `exec` no ENTRYPOINT é obrigatório se você usar `sh -c`.** Sem ele, o shell fica como PID 1 e o `SIGTERM` nunca chega na JVM — o container só para no timeout.
- **`-DskipTests` no build da imagem é intencional:** a suíte de testes é etapa anterior, de outra responsabilidade. Rodar testes durante o build da imagem acopla as duas coisas e deixa o build lento.
- **Migrations no boot** (Flyway, Liquibase, `ddl-auto`) exigem que o banco esteja pronto — é o caso clássico de `depends_on: condition: service_healthy`.
