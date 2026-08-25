FROM python:3.12-slim@sha256:dd29372629eeba2dd003fd9e9d35a5b8236c44727875a0364254b5127af88e65 AS dependencies

ARG PIP_INDEX_URL=https://pypi.org/simple
ARG UV_VERSION=0.12.5
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DEFAULT_TIMEOUT=120 \
    PIP_INDEX_URL=${PIP_INDEX_URL} \
    UV_DEFAULT_INDEX=${PIP_INDEX_URL} \
    UV_LINK_MODE=copy

WORKDIR /src
COPY upstream/ ./upstream/
RUN pip install "uv==${UV_VERSION}"

FROM dependencies AS builder
ENV UV_PROJECT_ENVIRONMENT=/opt/venv
RUN cd /src/upstream \
    && uv sync --frozen --no-dev --extra server --no-editable

FROM dependencies AS test
ARG PYTEST_XDIST_VERSION=3.8.0
ARG EXECNET_VERSION=2.1.2
ENV UV_PROJECT_ENVIRONMENT=/opt/test-venv
RUN cd /src/upstream \
    && uv sync --frozen \
    && uv run --frozen \
        --with "pytest-xdist==${PYTEST_XDIST_VERSION}" \
        --with "execnet==${EXECNET_VERSION}" \
        pytest -n auto -q

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
