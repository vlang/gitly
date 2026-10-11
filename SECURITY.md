# Security Policy

## Supported Versions

Gitly is beta software. Only the latest commit on `master` receives fixes. There
are no release branches and no backports; upgrade to the current `master` rather
than waiting for a patched version.

| Version | Supported |
| ------- | --------- |
| `master` (latest) | ✅ |
| anything older | ❌ |

## Reporting a Vulnerability

Do not open a public issue for a security problem.

Report privately through GitHub's private vulnerability reporting, which keeps the
report confidential until a fix is published:

**https://github.com/vlang/gitly/security/advisories/new**

If you cannot use that form, email the maintainers listed in `.github/FUNDING.yml`
and the repository owner, and include the words "gitly security" in the subject.

Please include:

- the affected route, command, or module
- a concrete reproduction, ideally the smallest program or HTTP request that shows it
- the impact you believe it has, and any preconditions (anonymous vs authenticated,
  which configuration flags are required)
- the V version and commit you tested against

You should receive an acknowledgement within 14 days. If the report is accepted,
the fix lands on `master` and the advisory is published when it is safe to do so.
If it is declined, you will be told why so you can decide whether to disclose it
yourself.

## Scope

Gitly is a self-hosted application. It is only security-relevant in the parts that
handle untrusted input, which in practice means:

- the HTTP routes under `repo/`, `issue_routes.v`, `pr_routes.v`,
  `api_v1_routes.v`, `platform_*_routes.v`, and the `*/ *_routes.v` files
- Git transport over HTTP and SSH (`repo/git_routes.v`, `ssh/`)
- the mirror, fork, and import paths, which fetch attacker-supplied URLs
  (`mirror.v`, `fork.v`, `repository_management.v`)
- credential and secret storage (`GITLY_STORAGE_SECRET`, mirror passwords,
  webhook secrets)
- the Markdown renderer, which parses untrusted documents (`markdown/`)
- the CI status callback, which is unauthenticated apart from its shared secret
  (`ci/ci_routes.v`)

Git transport over SSH delegates to the host OpenSSH server. Bugs in OpenSSH
itself, in the operating system, or in a reverse proxy in front of Gitly are out
of scope here; report them upstream.

## Out of Scope

- denial of service against an instance you control
- missing hardening that is documented as a deployment responsibility: HTTPS
  termination, reverse-proxy configuration, database credentials, and isolating
  the CI runner. See the production configuration section of the README.
- attacks requiring an already-authenticated maintainer or admin session, unless
  they cross a privilege boundary
- vulnerabilities in dependencies, including V's own standard library

## Known Boundaries

These are deliberate design decisions, not oversights. They are listed so that a
report can be triaged quickly.

- **The CI status callback is authenticated by a shared secret only.** Set
  `ci_secret` (or `GITLY_CI_SECRET`) before enabling CI. An empty secret causes
  callbacks to be rejected rather than accepted.
- **Mirror passwords, access tokens, and SSH private keys fail closed without
  `GITLY_STORAGE_SECRET`.** Set it before saving credentialed mirrors.
- **CI jobs are untrusted code.** Run the separate `gitly_ci` service on an
  isolated runner host with no access to Gitly's database credentials, storage
  secret, repository volume, or host filesystem. This is documented in the
  README and is the deployment's responsibility, not something Gitly can enforce
  from inside its own process.
- **Local object storage and repository paths are on the local filesystem.**
  `GITLY_OBJECT_STORAGE_PATH`, `GITLY_REPO_STORAGE_PATH`, `GITLY_ARCHIVE_PATH`,
  and `GITLY_AVATARS_PATH` should point at storage that is not shared with other
  services.

## Hardening Notes

Commands are executed by passing an argument vector to `git` rather than through
a shell, so route parameters, branch names, and file paths are never re-parsed by
`/bin/sh`. `git/git.v` documents this in `Git.exec_in_dir_with_env`. If you add
code that runs an external command, use an argument array; do not concatenate
user input into a string that is later handed to a shell.

Repository read access goes through `App.can_read_repo` (`repo/repo.v`), which
every repo-scoped read route calls before running a git command or returning repo
data. Add that check to any new repo-scoped route.

## Disclosure

Credited reporters are named in the published advisory unless they ask not to be.
