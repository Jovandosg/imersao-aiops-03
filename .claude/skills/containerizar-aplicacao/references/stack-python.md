# Stack Python

## Onde está cada evidência

| Evidência | Onde procurar |
|---|---|
| Versão do runtime | `.python-version`, `requires-python` no `pyproject.toml`, `python_requires` no `setup.py`, `runtime.txt` |
| Gerenciador de pacotes | qual manifesto existe: `requirements.txt` (pip), `pyproject.toml` + `poetry.lock` (Poetry), `uv.lock` (uv), `Pipfile.lock` (Pipenv) |
| Comando de start | `Procfile`, `[project.scripts]`, o README, ou o servidor WSGI/ASGI nas dependências |
| Porta | `app.run(port=)`, `--bind` do gunicorn, `--port` do uvicorn, `runserver` do Django. Default do Flask é 5000, do uvicorn 8000 |
| Env vars | `os.getenv(...)` / `os.environ.get(...)` — o segundo argumento é o default. Também classes `Settings` do pydantic |
| Serviços de dependência | `psycopg2`/`psycopg`/`asyncpg`, `PyMySQL`, `redis`, `pymongo`, `pika`, `celery` |
| Etapa de build | raramente; assets de frontend, `collectstatic` do Django, extensões Cython |
| Health | rotas `/health`, `/healthz`, ou o middleware de health do framework |

Com pydantic-settings o contrato fica concentrado numa classe só — é a melhor fonte quando existe:

```python
class Settings(BaseSettings):
    db_host: str = "localhost"
    db_port: int = 5432
```

## Lockfile → comando de install

| Manifesto | Instalação determinística |
|---|---|
| `requirements.txt` com versões pinadas | `pip install --no-cache-dir -r requirements.txt` |
| `poetry.lock` | `poetry install --only main --no-root` |
| `uv.lock` | `uv sync --frozen --no-dev` |
| `Pipfile.lock` | `pipenv install --deploy --system` |
| `requirements.txt` sem pin (`flask`, sem `==`) | funciona, mas avise que o build não é reprodutível |

Use sempre `--no-cache-dir` no pip: o cache não serve para nada dentro da imagem e só ocupa espaço na camada.

## Armadilhas de CWD

Python tem menos armadilhas que Node, porque os frameworks principais resolvem caminhos a partir do módulo — mas as que existem são igualmente silenciosas:

| Padrão | Resolve a partir de | Risco |
|---|---|---|
| `template_folder` / `static_folder` do Flask | diretório do módulo da app | seguro |
| `open('config.yaml')`, `load_dotenv('.env')` | CWD | alto |
| `STATICFILES_DIRS` / `MEDIA_ROOT` do Django com string relativa | CWD | alto |
| `BASE_DIR = Path(__file__).resolve().parent.parent` | arquivo | seguro — é o padrão do Django |
| `logging` com caminho de arquivo relativo | CWD | médio — o app sobe e falha ao logar |
| import do módulo de settings / app | `sys.path`, que inclui o CWD | alto — `ModuleNotFoundError` no start |

O problema mais comum não é caminho de arquivo, é **import**. `gunicorn app.main:app` só encontra o módulo se o CWD estiver no `sys.path`. Se o código vive em `src/`, o `WORKDIR` precisa ser o diretório que contém o pacote — ou o comando precisa de `--chdir`.

```dockerfile
# Ruim — o pacote está em /app/src/myapp, mas o CWD é /app
WORKDIR /app
COPY src/ ./src/
CMD ["gunicorn", "myapp.main:app"]   # ModuleNotFoundError

# Bom — o WORKDIR é o diretório que contém o pacote
WORKDIR /app
COPY src/ ./
CMD ["gunicorn", "myapp.main:app"]
```

## Dockerfile — venv copiado entre stages

O padrão mais limpo em Python: construir num virtualenv e copiar o venv inteiro para o runtime. Isola as dependências sem carregar o compilador na imagem final.

```dockerfile
# syntax=docker/dockerfile:1
ARG PYTHON_VERSION=3.12-slim

FROM python:${PYTHON_VERSION} AS deps
# Toolchain só existe neste stage — psycopg2 e afins precisam compilar
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libpq-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt ./
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -r requirements.txt

FROM python:${PYTHON_VERSION} AS runtime
# Só a lib de runtime, não a de desenvolvimento (libpq5, não libpq-dev)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libpq5 && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --create-home --uid 1001 app
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
COPY --from=deps /opt/venv /opt/venv
WORKDIR /app
COPY --chown=app:app src/ ./
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health').status==200 else 1)"
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "myapp.main:app"]
```

## Notas

- **`PYTHONUNBUFFERED=1` não é opcional em container.** Sem ele o stdout fica em buffer e os logs só aparecem quando o buffer enche — o container parece mudo, inclusive durante uma falha.
- **Alpine em Python geralmente é um mau negócio.** Sem wheels pré-compiladas para musl, o pip compila tudo do zero: o build fica lento e a imagem costuma sair *maior* que a `-slim`. Use `-slim` como default.
- **libc entre stages:** se o stage de build é `-slim` (glibc), o runtime também precisa ser. Misturar com Alpine faz o `.so` compilado não carregar.
- **`--workers` do gunicorn:** em container, prefira poucos workers e escale horizontalmente, em vez de calcular pelo número de CPUs do host — o container costuma ter menos CPU do que `os.cpu_count()` reporta.
- **Django:** o `collectstatic` roda no stage de build, não no start. Rodar no entrypoint atrasa cada boot e exige o volume de estáticos montado.
