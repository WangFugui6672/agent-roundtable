FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ARG UV_DEFAULT_INDEX=https://pypi.org/simple

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_HTTP_TIMEOUT=300 \
    UV_CONCURRENT_DOWNLOADS=1 \
    UV_DEFAULT_INDEX=$UV_DEFAULT_INDEX \
    PATH="/app/.venv/bin:$PATH"

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY . .

EXPOSE 8000

CMD ["daphne", "-b", "0.0.0.0", "-p", "8000", "roundtable.asgi:application"]
