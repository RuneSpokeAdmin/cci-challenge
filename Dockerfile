# syntax=docker/dockerfile:1
#
# Multi-stage build.
#   Stage 1 (builder): installs dependencies into a virtualenv with the full
#     toolchain available. This is the expensive layer.
#   Stage 2 (runtime): copies only the built virtualenv and the application
#     source into a slim image. No compilers, no build tooling ship to prod.
#
# Dependency manifests are copied BEFORE the application source so the costly
# `pip install` layer is only invalidated when dependencies actually change -
# a code edit hits the cheap final layer, not a full reinstall.

# ---------- Stage 1: builder ----------
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Build deps needed to compile psycopg2 etc. Present only in this stage.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Manifest first - this is the caching optimization.
COPY requirements.txt .

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install -r requirements.txt

# ---------- Stage 2: runtime ----------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# libpq for the psycopg2 runtime; no compilers.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 appuser

# Copy the built virtualenv from the builder stage.
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY app/ ./app/

# Drop root - the container runs as an unprivileged user.
USER appuser

EXPOSE 8000

# Simple healthcheck against the liveness endpoint.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/health').status==200 else 1)" || exit 1

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app.wsgi:app"]
