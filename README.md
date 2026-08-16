# Tools Registry Image Pipeline

This standalone repository builds the public
[`superdesigndev/tools-registry`](https://github.com/superdesigndev/tools-registry)
source outside the production ECS host. GitHub Actions runs the upstream pytest suite,
publishes an immutable candidate to GHCR, and requires an explicit workflow dispatch to
promote that exact manifest to `stable`.

No production database, Treg runtime secret, SSH key, GitHub personal access token, or
Docker Hub credential belongs in this repository.

## Release flow

```text
upstream main/tag/SHA
        |
        v
build-candidate.yml
  fetch exact SHA -> build test target -> pytest -> runtime image
        |
        v
ghcr.io/OWNER/tools-registry:candidate-v1-<40-char-upstream-sha>
        |
        | operator dispatches promote-stable.yml
        v
ghcr.io/OWNER/tools-registry:stable + immutable stable-v1-<sha>
        |
        | ECS resolves and pins sha256 digest
        v
pull -> PostgreSQL dump -> recreate -> container/public health -> rollback on failure
```

Neither workflow deploys to ECS. The build job therefore needs no ECS SSH key and cannot
change production. The package should be public because the image contains only public
upstream code; runtime secrets remain injected by ECS Compose.

## GitHub repository setup

Create an empty public repository named `tools-registry-image`, then push this repository's
`main` branch. No repository secret is required: GHCR publication uses the workflow's
repository-scoped `GITHUB_TOKEN`.

After the push:

1. In **Settings -> Actions -> General**, allow GitHub Actions and confirm organization
   policy does not block the workflow's declared `packages: write`, `attestations: write`,
   and `id-token: write` permissions.
2. In **Settings -> Environments**, create `production-promotion`. Add a required reviewer
   so `stable` cannot move without an explicit approval.
3. Run **Build candidate image** once. After GHCR creates the package, open its package
   settings and change visibility to **Public** so ECS can pull without a registry secret.
4. Run **Promote candidate to stable** with the exact candidate tag only after its test job
   is green.

Do not add a Docker Hub token or ECS SSH key. Docker Hub mirroring is intentionally outside
this approved GHCR-only path and can be designed later if it becomes necessary.

## Candidate build

`.github/workflows/build-candidate.yml` runs:

- every day at `20:17 UTC`;
- manually with an optional upstream branch, tag, or commit;
- on changes to this repository; and
- as a test-only job for pull requests.

The immutable candidate tag contains the pipeline epoch and full upstream commit. If build
semantics change, increment `PIPELINE_EPOCH` in `pipeline.env`. Existing candidate tags are
never overwritten.

The workflow pins all third-party Actions to full commit SHAs. It publishes an SBOM,
BuildKit provenance, and a GitHub artifact attestation. The Python base image is also
pinned by digest; Dependabot proposes reviewed digest and Action updates weekly.

## Stable promotion

After reviewing the candidate workflow and test result:

1. Open **Actions -> Promote candidate to stable -> Run workflow**.
2. Enter the exact candidate tag shown in the candidate build summary.
3. Approve the `production-promotion` environment when protection is configured.
4. Record the resulting digest from the workflow summary.
5. For the first releases, run `scripts/deploy-digest.sh --dry-run DIGEST` on ECS and then
   explicitly set `TREG_DEPLOY_CONFIRMED=1` for the real deployment.

Promotion copies the existing manifest. It does not rebuild the image. The moving `stable`
tag is accompanied by an immutable `stable-v1-<sha>` tag.

## First ECS deployment

Keep the old `treg-update.timer` disabled. Copy the two scripts to a root-owned directory,
then configure the public GHCR image name. Do not install or enable the new timer until
several manual promotions and rollbacks have been verified.

Example preparation commands, to be executed only during an approved deployment window:

```bash
install -d -m 0755 /usr/local/libexec/treg-registry-deploy
install -m 0755 scripts/deploy-digest.sh \
  /usr/local/libexec/treg-registry-deploy/deploy-digest.sh
install -m 0755 scripts/check-stable-and-deploy.sh \
  /usr/local/libexec/treg-registry-deploy/check-stable-and-deploy.sh
install -m 0600 systemd/treg-registry-deploy.env.example \
  /etc/treg-registry-deploy.env
```

Edit only `TREG_REGISTRY_IMAGE` in `/etc/treg-registry-deploy.env`, then verify:

```bash
TREG_REGISTRY_IMAGE=ghcr.io/OWNER/tools-registry \
  /usr/local/libexec/treg-registry-deploy/deploy-digest.sh \
  --dry-run sha256:<64-hex-digest>
```

The real command requires the one-shot write gate:

```bash
TREG_REGISTRY_IMAGE=ghcr.io/OWNER/tools-registry \
TREG_DEPLOY_CONFIRMED=1 \
  /usr/local/libexec/treg-registry-deploy/deploy-digest.sh \
  sha256:<64-hex-digest>
```

The deployer refuses to start unless the current Treg container is healthy. It pulls the
exact digest, verifies Linux/amd64 and the upstream revision label, creates and validates a
PostgreSQL dump, preserves the old local image as `gateway-stack/treg:rollback`, recreates
only `treg`, and rolls back if either Docker health or the public `/meta` probe fails.

## Deferred automatic timer

`systemd/treg-registry-update.*` is a disabled template. After manual releases prove the
path, install the units and enable the timer in a separate approved change. The checker
refuses its first automatic run until a successful manual deployment has written
`/var/lib/treg-registry-deploy/last-successful-digest`.

It only resolves `stable` and calls the digest deployer when the promoted digest changes.
It never builds, prunes, or removes images or Docker volumes.

## Local validation

```bash
tests/test-contract.sh
docker run --rm -v "$PWD:/repo" --workdir /repo \
  rhysd/actionlint:1.7.12 \
  .github/workflows/build-candidate.yml \
  .github/workflows/promote-stable.yml
```

If Docker is available, an optional full upstream build can be run with:

```bash
source pipeline.env
revision=$(scripts/fetch-upstream.sh "$UPSTREAM_DEFAULT_REF" upstream)
docker build --target test \
  --build-arg "TREG_SOURCE_REVISION=$revision" \
  --build-arg "TREG_PIPELINE_REVISION=local" .
```

The `upstream/` build context is ignored by Git and must never contain local credentials.
