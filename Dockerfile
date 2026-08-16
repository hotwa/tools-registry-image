FROM python:3.12-slim@sha256:dd29372629eeba2dd003fd9e9d35a5b8236c44727875a0364254b5127af88e65 AS builder

ARG PIP_INDEX_URL=https://pypi.org/simple
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DEFAULT_TIMEOUT=120 \
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    VIRTUAL_ENV=/opt/venv

RUN python -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /src
COPY upstream/ ./upstream/
RUN pip install --upgrade pip \
    && pip install "./upstream[server]"

FROM builder AS test
RUN pip install pytest pytest-asyncio \
    && cd /src/upstream \
    && pytest -q

FROM python:3.12-slim@sha256:dd29372629eeba2dd003fd9e9d35a5b8236c44727875a0364254b5127af88e65 AS runtime

ARG TREG_SOURCE_REVISION=unknown
ARG TREG_PIPELINE_REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/superdesigndev/tools-registry" \
      org.opencontainers.image.revision="$TREG_SOURCE_REVISION" \
      io.jmsu.treg.pipeline-revision="$TREG_PIPELINE_REVISION"

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=18790

RUN groupadd --gid 10001 treg \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin treg

COPY --from=builder /opt/venv /opt/venv

USER 10001:10001
EXPOSE 18790
HEALTHCHECK --interval=20s --timeout=5s --start-period=30s --retries=6 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:18790/meta', timeout=3)"

CMD ["python", "-m", "treg"]
