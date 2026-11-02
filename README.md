# Gitly

![CI](https://github.com/vlang/gitly/workflows/CI/badge.svg?branch=master)

Gitly is a lightweight, self-hosted GitHub/GitLab alternative written in V.

It provides:

- Multiple users, personal and organization repositories, and public/private visibility
- Git clone, fetch, and push over HTTP(S) and OpenSSH
- Repository browsing, syntax highlighting, Markdown rendering, language statistics, and a “Top files” view
- Editable issues with assignees and project labels; merge requests with reviews, required approvals, squash/merge support; plus discussions, projects, milestones, releases, stars, and watches
- Reporter/Developer/Maintainer project roles and branch creation/deletion with protected-branch wildcard rules, push/merge controls, deletion protection, and force-push rejection
- Webhooks, scoped/expiring personal access tokens, two-factor authentication, security logs, and optional CI integration
- Repository forks with upstream synchronization and cross-fork merge requests
- Scheduled/manual pull and push mirrors over HTTPS or SSH, with encrypted credentials
- Deploy tokens, trusted SSH commit signatures, signed-commit policies, protected tags and releases, snippets, Git LFS, partial clone, and scheduled/manual repository housekeeping
- Nested groups with inherited planning access, epics and roadmaps, iterations, issue tasks/time/relationships, scoped labels, service desk ingestion, and filtered boards with WIP limits
- Package and OCI container registries, dependency proxying, provenance, retention, and content-addressed local/HTTP object storage
- Security-report ingestion, vulnerability management, compliance and merge policies, audit export, cluster agents, feature flags, incidents, alerting, telemetry, and on-call schedules
- Background queues, HA health/heartbeats, verified backups, quotas, abuse limits, encrypted directory-provider configuration, SCIM provisioning, and group/project import-export
- SQLite or PostgreSQL storage and compiled-in templates

Gitly is beta software. It is a lightweight forge rather than a complete GitLab distribution. It supplies an integrated platform control plane while scanner engines, native LDAP/SAML protocol handling, managed observability backends, multi-region orchestration, and the separately maintained CI runner remain external services.

The current GitLab capability comparison and the remaining implementation sequence are documented in [docs/gitlab-parity.md](docs/gitlab-parity.md). Gitly is intentionally described as a lightweight alternative, not as complete GitLab parity while major platform areas remain outstanding. The comparison against Gitea, which is the closer-sized forge and therefore the more useful bar, is in [docs/gitea-parity.md](docs/gitea-parity.md).

## Build and run

A recent V compiler, Git, and a C compiler are required. Install `sassc` to compile the stylesheet on a clean checkout; the build intentionally does not download unpinned generated assets. The Markdown module is included in this repository.

Build with:

```sh
v run build.vsh
./gitly
```

Gitly builds against PostgreSQL by default. Create the default local role and database with:

```sh
v run setup_db.vsh
```

To use SQLite instead:

```sh
v -d sqlite -o gitly .
./gitly
```

The SQLite database defaults to `gitly.sqlite`; change it with `sqlite.path` in `config.json` or `GITLY_SQLITE_PATH`. Repository, archive, and avatar storage can be overridden with `GITLY_REPO_STORAGE_PATH`, `GITLY_ARCHIVE_PATH`, and `GITLY_AVATARS_PATH`. PostgreSQL accepts the `pg` configuration block, `GITLY_DB_*` variables, the usual `PG*` variables, or `DATABASE_URL`.

System libraries:

- SQLite: `libsqlite3-dev` on Ubuntu/Debian
- PostgreSQL: `libpq-dev` on Ubuntu/Debian or `brew install libpq` on macOS
- Stylesheet compilation: `sassc`

## Production configuration

Review `config.json` before deployment:

- Set `hostname` to the public host.
- Set `cookie_secure` to `true` whenever the site is served over HTTPS.
- Set `ci_secret` to a long random value if CI is enabled, and configure the same secret in the CI service. CI callbacks are rejected when this secret is empty. `GITLY_CI_SECRET` can override the Gitly-side value.
- Gitly derives the CI status callback from `hostname` and `cookie_secure`. If the CI service cannot reach that URL, set `ci_callback_url` (or `GITLY_CI_CALLBACK_URL`) to the complete externally reachable callback endpoint, for example `https://git.example.com/api/v1/ci/status`.
- Set `GITLY_STORAGE_SECRET` to a long random value before saving credentialed repository mirrors. Mirror passwords, access tokens, and SSH private keys fail closed when encryption is not configured.
- Binary artifacts default to a content-addressed store under the repository root. Set `GITLY_OBJECT_STORAGE_PATH` for a separate local volume, or `GITLY_OBJECT_STORAGE_URL` and `GITLY_OBJECT_STORAGE_TOKEN` for the authenticated HTTP adapter. Configure `GITLY_MAX_PACKAGE_SIZE_BYTES` and an explicit `GITLY_DEPENDENCY_PROXY_ALLOWED_HOSTS` allowlist for registry traffic.
- Give each web/worker process a stable `GITLY_INSTANCE_ID` when operating multiple instances. All instances must share the database, repository volume, object store, storage secret, and HTTPS/session configuration.
- Keep the CI service and database on trusted networks and terminate HTTPS at Gitly or a reverse proxy.
- Treat CI jobs as untrusted code. Run the separate `gitly_ci` service on an isolated runner host/VM (or an equivalent container sandbox) with a minimal allowlisted environment and no access to Gitly's database credentials, storage secret, repository storage, or host filesystem beyond its disposable workspace. Do not co-locate the current shell runner with the Gitly service in production.

### SSH transport

Gitly uses the host OpenSSH server instead of embedding a second SSH daemon. Configure a dedicated SSH account and set:

```sh
export GITLY_SSH_ENABLED=true
export GITLY_SSH_HOSTNAME=git.example.com
export GITLY_SSH_PORT=22
export GITLY_SSH_USER=git
export GITLY_SSH_AUTHORIZED_KEYS_PATH=/home/git/.ssh/authorized_keys
```

The Gitly process must be able to atomically update that file. It preserves entries outside its managed block and installs restricted forced commands for active authentication and deploy keys. See [docs/ssh.md](docs/ssh.md) for the OpenSSH setup and security model.

Fork and mirror behavior, including private-source visibility, divergence handling, credential encryption, SSH host-key pinning, and internal-host allowlisting, is documented in [docs/repository-forks-mirrors.md](docs/repository-forks-mirrors.md).

Package delivery, security ingestion, operational APIs, backups, identity provisioning, and scaling configuration are documented in [docs/platform.md](docs/platform.md).

## Tests

Run the tracked test suite with SQLite support:

```sh
v -d sqlite test $(git ls-files '*_test.v')
```

The end-to-end first-run check uses a process-specific port and isolated temporary database/storage, then clones a public repository:

```sh
v run tests/first_run.v
```

## Notable design goals

- Small memory and deployment footprint
- Useful repository navigation without requiring JavaScript
- CI-aware releases whose source tree remains identifiable
- Explicit repository-transfer acceptance, so another user cannot force content into an account namespace
