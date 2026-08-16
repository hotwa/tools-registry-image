# Security boundaries

- GitHub Actions receives only the repository-scoped `GITHUB_TOKEN` needed to publish the
  repository's GHCR package. Do not add ECS SSH credentials to the build workflow.
- Keep the GHCR image public while it contains only the public upstream application. If
  private code is added later, stop and design a root-only ECS registry credential flow.
- Production Treg environment variables, PostgreSQL contents, API tokens, OAuth secrets,
  encryption keys, and Lucky credentials are runtime state and never enter the image.
- Candidate tags and immutable stable tags are not overwritten. Production deploys consume
  a `sha256` digest, not `latest` or another moving tag.
- Do not enable workflows from untrusted forks with write tokens. Pull requests build and
  test but never log in to GHCR or publish.
- Action dependencies are pinned to full commit SHAs. Review and update those pins through
  an explicit pull request.
- The ECS deployer never runs `docker image prune`, `docker volume prune`, or database
  migrations outside normal application startup. It recreates only the `treg` service.
