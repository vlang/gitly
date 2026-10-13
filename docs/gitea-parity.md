# Gitea parity

Gitly describes itself as a lightweight GitHub/GitLab alternative. This document
makes the comparison against **Gitea** explicit, because Gitea is the realistic
bar for a self-hosted forge of this size: it is open source, it targets a single
node, and it solves the same problem Gitly solves. GitLab is a much larger
DevSecOps platform and is tracked separately in [gitlab-parity.md](gitlab-parity.md).

The bar here is Gitea's own feature matrix, not everything Gitea can do. Where
Gitly deliberately does something lighter, that is recorded rather than treated
as a defect.

## Source of truth

<https://docs.gitea.com/installation/comparison> — Gitea's official "Compared to
other Git hosting" table. Checked against Gitea docs version 28 on 2026-10-13.

Gitea's own caveat on that page: *"we don't regularly check for feature changes
in other products, so this list may be outdated."* The symbols below are Gitea's
(✓ / ⁄ / ✘ / ⚙️), so a ✓ in the "Gitea" column is Gitea's claim about Gitea, and
Gitly's status was then checked against this repository's code.

Every Gitly status that says ✓ or ~ was verified against source in this tree. Any
row where that was not possible is listed under
[Not verified](#not-verified) at the end rather than being guessed.

Symbols in the "Gitly" column:

- ✓ implemented
- ~ present but partial, or present in a form that does not meet Gitea's claim
- ✘ not implemented
- ⚙️ supplied by an adjacent service rather than this repository

The "Gitea" column is Gitea's own claim about Gitea, copied from its table.

## Implemented and verified

Checked against this tree at the time of writing. `file:line` points at the
evidence.

### General

| Gitea | Feature | Gitly |
| --- | --- | --- |
| ✓ | Open source and free | ✓ GPL-3.0, `LICENSE` |
| ✓ | Low RAM / CPU usage | ✓ V, single binary |
| ✓ | Multiple database support | ✓ `database_d_sqlite.v` / `database_notd_sqlite.v` |
| ✓ | Multiple OS support | ✓ CI covers ubuntu-gcc, macos-clang, windows-gcc, ubuntu-tcc |
| ✘ | Telemetry | ✓ absolutely none, no phone-home anywhere |
| ✓ | WebAuthn (2FA) | ✘ see *Missing* |
| ✓ | Audit log | ✓ `security/security_log.v`, plus append-only audit export |
| ✓ | Extensive API | ✓ `api_v1_routes.v`, `api/` module |
| ✓ | Built-in package / container registry | ✓ OCI v2 plus npm, Maven, PyPI, NuGet, Composer, Helm |
| ✓ | Push mirror | ✓ `mirror.v` |
| ✓ | Pull mirror | ✓ `mirror.v`, encrypted credentials |
| ✓ | Markdown support | ✓ `markdown/md4c` vendored |
| ✓ | Gists / snippets | ✓ `templates/snippet.html`, snippet routes |
| ✓ | Deploy tokens | ✓ documented in README |
| ✓ | Repository tokens with write rights | ✓ `api_token.v`, scoped and expiring |
| ✓ | Subgroups (groups within groups) | ✓ nested groups with inherited planning access |
| ⚙️ | GitLab Pages | ✘ out of scope, see below |
| ✓ | Mermaid diagrams in Markdown | ✘ see *Missing* |
| ✓ | Math syntax in Markdown | ✘ see *Missing* |

### Code management

| Gitea | Feature | Gitly |
| --- | --- | --- |
| ✓ | Git LFS 2.0 | ✓ `lfs_routes.v` |
| ✓ | Granular user roles | ✓ `repo_access_level`, `project_member.v` |
| ✓ | Reject unsigned commits | ✓ `Repo.require_signed_commits` |
| ✓ | SSH signed commits | ✓ `ssh/ssh_key.v`, trusted SSH commit verification |
| ✓ | Migrating repos from other services | ✓ clone URL plus group/project import-export |
| ✓ | Repository activity page | ✓ `activity.v` |
| ✓ | Branch manager | ✓ `repo/branch.v`, `repo/branch_routes.v` |
| ✓ | Create new branches | ✓ `repo/branch_routes.v` |
| ✓ | Web code editor | ✓ `templates/edit_file.html`, `repo/file_routes.v` |
| ✓ | Template repositories | ✓ `repo/repo_template.v` and `repo_template_test.v` |
| ✓ | Download patch | ✓ PR read-patch support |
| ⁄ | Repository code search | ~ searches repositories and users only, no code, see *Missing* |
| ✓ | Global code search | ✘ see *Missing* |
| ✓ | Commit graph | ✘ see *Missing* |
| ✓ | Git blame | ✘ see *Missing* |
| ✓ | Visual comparison of image changes | ✘ see *Missing* |

### Issue tracker

| Gitea | Feature | Gitly |
| --- | --- | --- |
| ✓ | Issue tracker | ✓ `issue.v`, `issue_routes.v` |
| ✓ | Labels | ✓ `label_routes.v` |
| ✓ | Time tracking | ✓ time estimates and entries on issues |
| ✓ | Multiple assignees | ✓ `issue.v:15` `assigned []int`, `IssueAssignee` join table |
| ✓ | Related issues | ✓ issue relationships |
| ✓ | Issue dependency | ✓ same relationship model |
| ✓ | Projects | ✓ `project.v`, `project_routes.v` |
| ✓ | Lock discussion | ✓ `Discussion.is_locked`, checked at `api_v1_routes.v:779` |
| ✓ | Service desk | ✓ token-authenticated ingestion |
| ✓ | Issue templates | ✘ see *Missing* |
| ✓ | Confidential issues | ✘ see *Missing* |
| ✓ | Comment reactions | ✘ see *Missing* |
| ✓ | Batch issue handling | ✘ see *Missing* |
| ✘ | Create branch from issue | ✘ Gitea does not have it either |
| ✓ | Convert comment to new issue | ✘ see *Missing* |
| ✘ | Create issue via email | ✘ Gitea does not have it either; #257 covers SMTP |

### Pull requests

| Gitea | Feature | Gitly |
| --- | --- | --- |
| ✓ | Pull requests | ✓ `pr.v`, `pr_routes.v` |
| ✓ | Squash merging | ✓ `pr_merge_test.v` |
| ✓ | Inline comments | ✓ `repo/comment.v` |
| ✓ | Approval | ✓ approvals with invalidation |
| ✓ | Require approval | ✓ required approvals |
| ✓ | Restrict push and merge | ✓ `protected_branch.v` |
| ✓ | Webhooks | ✓ `webhook.v`, `webhook_routes.v` |
| ✓ | Git hooks | ~ `protected_branch.v:228` covers pre-receive policy, not arbitrary custom hooks |
| ✓ | 2FA | ✓ TOTP in `two_factor.v` |
| ⁄ | Rebase merging | ✘ see *Missing* |
| ✓ | Pull request templates | ✘ see *Missing* |
| ✓ | Multiple reviewers | ? not verified |
| ✘ | Merge conflict resolution in the UI | ✘ Gitea does not have it either |
| ✓ | Revert specific commits | ✘ see *Missing* |
| ✓ | Cherry-picking changes | ✘ see *Missing* |
| ✓ | Merge queues | ✘ see *Missing* |

### Third-party integrations

| Gitea | Feature | Gitly |
| --- | --- | --- |
| ✓ | Built-in CI/CD | ⚙️ separate `gitly_ci` by design |
| ⁄ | OAuth 2.0 external authorization | ~ GitHub OAuth exists in `github.v` but is broken, #149 and #134 |
| ✓ | Act as OAuth 2.0 provider | ✘ see *Missing* |
| ✓ | AD / LDAP integration | ~ `platform_admin.v:513` validates and encrypts provider configuration only; no bind, see *Missing* |
| ✓ | Multiple LDAP / AD servers | ✘ |
| ✓ | LDAP user synchronisation | ✘ |
| ✓ | SAML 2.0 service provider | ✘ |
| ✓ | OpenID Connect | ✘ |

## Missing, in dependency order

The order below is a work queue, not a wish list. Each entry is something Gitea
ships and Gitly does not, ordered so that prerequisites come first.

1. **Wiki.** Gitea ships it as a git repository of its own, which means the
   storage model is the easy part. Gitly currently has the *setting* without the
   feature. See the next section.
2. **Repository topics.** Gitea stores them as first-class records. Gitly has a
   counter. Cheap to add, and it feeds the explore page, which is currently the
   weakest discovery surface.
3. **In-repo code search.** `search_routes.v:31` restricts `type` to `repos` and
   `users`, so there is no way to search inside a repository. Gitea's built-in
   indexer is the model; the approach does not have to match, but a code-search
   box has to exist before "global code search" means anything.
4. **Comment reactions.** Smallest missing collaboration feature, and users
   notice its absence immediately.
5. **Issue and PR templates.** Gitea reads `.gitea/ISSUE_TEMPLATE*` and
   `PULL_REQUEST_TEMPLATE*` from the repository default branch. Gitly has no
   equivalent convention, so new issues start blank.
6. **Batch issue handling.** Selecting several issues and applying a label,
   milestone, or assignee in one action.
7. **Convert comment to new issue.** Depends on the issue and comment models
   that already exist.
8. **Confidential issues.** Visible to reporter and above only. Needs a
   visibility column on `Issue` and a check alongside the existing
   `can_read_repo` pattern.
9. **Commit graph and git blame.** Both need a history walk over the repository,
   so they belong together. `repo/branch.v` already walks refs; the missing piece
   is reading the commit graph from git rather than the database.
10. **Mermaid and math in Markdown.** Both are post-processing passes over
    `markdown/md4c` output. Both are also an XSS surface, so they need the same
    sanitisation that already guards Markdown rendering.
11. **Rebase merging as a selectable merge method.** Squash and merge exist;
    rebase does not. Today `pr_routes.v:747` refuses to create a merge commit
    when signed commits are required, so rebase is also the path to making that
    combination work.
12. **Revert and cherry-pick a commit.** Both are "apply this diff to a branch"
    operations, so they share an implementation. Needs the fast-forward and
    conflict handling that rebase merging also needs.
13. **Merge queues.** A queue that merges PRs one at a time once CI is green.
    Depends on the CI status plumbing that already exists in `ci/`.
14. **OAuth 2.0 provider.** Lets Gitly be an identity provider for other tools.
    This is the largest item here and should not be started until the GitHub
    OAuth *consumer* path works.
15. **Native LDAP and SAML.** Currently configuration only, which is a real gap
    against Gitea's supported mark on the basic AD/LDAP row. Treat these as a
    deployment-gateway concern unless someone wants to own them fully.

## Stubs that imply features that do not exist

These are worse than plain gaps, because a settings screen suggests the feature
is one click away.

- **Wiki.** `repo/repo.v:49` declares a `disable_wiki` column, `repo.v:69`
  defines `wiki_enabled()`, and `update_repo_features` persists the toggle — but
  there is no wiki content model, no wiki route, and no wiki template anywhere
  in the tree. A repository owner can turn the wiki on and then find nothing.
  Either implement the wiki or remove the setting.
- **Topics.** `repo/repo.v:23` declares `nr_topics int @[skip]` and
  `repo/repo_template.v:87` formats the count, but there is no topic model, no
  route assigning topics, and nothing increments the counter. The explore page
  therefore shows a number that is always zero.

Both are cheap to verify and should be either implemented or hidden before
Gitly advertises Gitea parity anywhere.

## Deliberately out of scope

Recorded so these are not re-raised as defects:

- **Built-in CI/CD.** Gitly ships a status consumer and a separate runner. This
  is the same split Gitea uses with Gitea Actions, and it is documented in
  [gitlab-parity.md](gitlab-parity.md). The gap is a runner distribution, not a
  data model.
- **GitLab Pages and Pages hosting.** Static serving is a deployment concern.
- **Merge conflict resolution in the UI.** Gitea does not ship it either; it
  points users at the command line.
- **Create branch from issue, and create issue via email.** Gitea itself marks
  both unsupported.
- **SAML and multi-server LDAP.** These need a real identity gateway and are
  documented as external in [platform.md](platform.md).

## Not verified

Listed rather than guessed, so a reader does not mistake an unexamined row for a
negative one:

- **Multiple PR reviewers.** `reviewer` matches only `database_test.v`, which is
  not a reviewer model. Approval entity exists; the reviewer count is unknown.
- **Repository topics as user-visible strings.** Confirmed absent as a model;
  the UI surface was not audited for a topic input.
- **Batch issue handling surface.** The issue model was checked, not the UI.
- **Git hook extensibility.** `protected_branch.v:228` enforces policy; whether
  arbitrary custom hooks can be installed per repository was not traced.
