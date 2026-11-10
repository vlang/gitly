# Roadmap to Gitea parity

Companion to [gitea-parity.md](gitea-parity.md). That document is the *status*
matrix; this one is the *plan*: what to build, in what order, and why.

## Guiding principles

1. **Honesty first.** Stubs that advertise features Gitly does not have
   (wiki toggle, topics counter) are worse than gaps. Remove or implement them
   before anything else, so the parity matrix stays trustworthy.
2. **Prerequisites before features.** Code search before global code search.
   Commit graph before blame. GitHub OAuth consumer before OAuth provider.
3. **One PR per item.** Each item below is scoped to a single reviewable PR
   with tests. No mega-PRs.
4. **Tests gate merges.** Every item ships with a regression test that fails
   on the old code. Compilation alone is not evidence (see gitea-parity review
   history).

## Phase 0 - Honesty (1-2 days)

Remove or hide features that are advertised but not implemented.

- **Wiki stub.** `repo/repo.v` declares `disable_wiki` and `wiki_enabled()`,
  and `update_repo_features` persists the toggle, but there is no wiki content
  model, route, or template. Either implement the wiki (Phase 3) or drop the
  setting now. Recommendation: drop the setting now, re-add with the feature.
- **Topics stub.** `nr_topics` is declared and formatted but never incremented
  and there is no topic model or route. Drop the counter until topics ship.

Deliverable: two small PRs, no behaviour change for real features.

## Phase 1 - Quick wins (1 week)

Small, self-contained features with high user visibility.

1. **Repository topics.** First-class `Topic` model + join table, routes to
   assign topics, topic badges on repo header, topic filter on explore page.
   Feeds the weakest discovery surface.
2. **Comment reactions.** Emoji reactions on issue/PR comments. New
   `CommentReaction` model, toggle endpoint, rendered counts. Smallest missing
   collaboration feature.
3. **Issue and PR templates.** Read `.gitea/ISSUE_TEMPLATE*` and
   `PULL_REQUEST_TEMPLATE*` from the default branch when creating an issue/PR.
   No new storage model; templates live in the repo.
4. **Batch issue handling.** Select multiple issues, apply label/milestone/
   assignee in one action. UI + bulk endpoint.

## Phase 2 - Developer experience (2-3 weeks)

Features developers use daily.

5. **In-repo code search.** Extend `search_routes.v` beyond `repos`/`users`
   to search file contents. Start with a grep over the working tree; add an
   indexer later. Required before "global code search" means anything.
6. **Commit graph.** Render the commit DAG for a repository. Needs a history
   walk over git (not the DB). Reuses ref-walking code in `repo/branch.v`.
7. **Git blame.** Per-line authorship via `git blame`. Pairs with commit
   graph.
8. **Mermaid and math in Markdown.** Post-processing passes over
   `markdown/md4c` output. Both are XSS surfaces; reuse existing sanitiser.
   Add tests for script injection.
9. **Visual image diff.** Side-by-side image comparison on PR file views.

## Phase 3 - Pull request workflow (2-3 weeks)

Completes the review/merge story.

10. **Rebase merging** as a selectable merge method. Also unblocks signed
    commits + merge commits (`pr_routes.v:747`).
11. **Revert and cherry-pick a commit.** Shared "apply this diff to a branch"
    implementation; needs fast-forward and conflict handling.
12. **Merge queues.** Merge PRs one at a time once CI is green. Reuses
    `ci/` status plumbing.
13. **Wiki.** Git repository of Markdown pages, rendered like repo files.
    Re-add the `disable_wiki` toggle removed in Phase 0, now backed by a
    real model.
14. **Confidential issues.** Visibility column on `Issue` plus a check
    alongside `can_read_repo`.

## Phase 4 - Identity and enterprise (4+ weeks)

Largest items; only start after Phase 1-3 are stable.

15. **OAuth 2.0 provider.** Gitly as an identity provider. Start only after
    the GitHub OAuth *consumer* path works (#149, #134).
16. **LDAP bind + user sync.** Move from config-only to a real bind and sync.
17. **SAML 2.0 service provider.** Likely needs an external identity gateway;
    document as external unless someone owns it fully.
18. **Multiple LDAP/AD servers and OpenID Connect.**

## Suggested first PR

Implement **repository topics** (Phase 1, item 1). It is the cheapest
feature that turns a stub into a real capability, touches a clear vertical
slice (model + routes + template + explore page), and has an obvious test
(topics round-trip and explore filtering). It also removes the "always zero"
counter called out in the stubs section.

## Tracking

- Status matrix: `docs/gitea-parity.md`
- This roadmap: `docs/gitea-roadmap.md`
- Each item becomes one PR referencing the numbered item above.
