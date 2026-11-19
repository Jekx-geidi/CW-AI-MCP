FROM python:3.12-slim

RUN pip install --no-cache-dir uv==0.11.21 \
    && useradd --create-home --uid 10001 app

WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY src ./src
# Install exactly the locked dependency versions, then the package itself.
RUN uv export --frozen --no-dev --no-emit-project -o /tmp/requirements.txt \
    && uv pip install --system --no-cache -r /tmp/requirements.txt \
    && uv pip install --system --no-cache --no-deps . \
    && rm /tmp/requirements.txt

USER app
EXPOSE 8000
# Binds inside the Octelium sidecar's network namespace only (no host ports).
CMD ["cw-reports-mcp", "--host", "0.0.0.0", "--port", "8000"]
