# Fix failed CI with Gitly AI

Gitly can propose a code fix for a failed pull request pipeline using a Claude or OpenAI API key supplied by the user. The action uses the current source branch commit and its latest recorded CI attempt. It does not require a server-wide AI credential.

## Use the action

1. Open a pull request whose current source commit has a failed or timed-out CI run.
2. Select **Fix with Gitly AI** in the CI status panel.
3. Choose **Claude (Anthropic)** or **Codex (OpenAI)**, enter that provider's API key, and optionally specify a model ID available to the key.
4. Select **Generate fix**. Gitly sends a bounded context containing the pull request diff, selected source files, and failed CI logs to the chosen provider.
5. Review the explanation and complete proposed patch, then select **Commit fix and rerun CI** to add a commit to the pull request's source branch. Cancel returns to the pull request without changing the branch.

The proposed changes have not been executed or tested by Gitly AI. After a commit is accepted, Gitly requests a new pipeline through its normal CI integration if CI is configured for that branch. A proposal is an attempt to fix the failure, not a guarantee that the new run will pass. The AI may instead return an explanation without a patch; that response has no commit action.

## Setup and access

Configure the normal Gitly CI service and shared CI authentication secret first; see [Production configuration](../README.md#production-configuration). The Gitly server needs HTTPS access to the selected provider's API. Use HTTPS for the Gitly site when submitting API keys.

The action is available only for open pull requests to users who can read both the target and source repositories and push to the source branch. Protected branch permissions still apply. Gitly does not generate commits for a source repository that requires user-signed commits. For a pull request from a fork, the fix is committed to the fork's source branch.

An old failed run on the same branch does not enable the action for a newer untested commit. Gitly checks the full source commit ID, repository, branch, and latest CI attempt before generation and again before applying a fix. If the branch or run changes while the page is open, reload the action and generate a new proposal.

## Credentials and context

The API key is used for one generation request. Gitly does not store it in the database, repository, browser storage, or review form, and does not include it in the AI prompt. The key field is blank when a request fails; enter the key again to retry. Provider usage charges may apply.

Claude requests use the Anthropic Messages API with `claude-sonnet-5-5` by default; Codex requests use the OpenAI Responses API with `gpt-6.1-sol` by default. Leave the model field empty to use that default, or set an explicit model ID for another compatible model available to your key. Provider URLs are fixed HTTPS endpoints, redirects are disabled, and requests have timeouts. OpenAI requests set `store: false`.

Provider references: [Claude API](https://platform.claude.com/docs/en/api/overview), [Claude models](https://platform.claude.com/docs/en/models/overview), and [OpenAI code generation](https://developers.openai.com/api/docs/guides/code-generation).

Review the data-sharing notice before generating a proposal, particularly for private code or logs. The selected provider receives the context through its API under your account. Context sizes are capped, so large pull requests or long logs may omit material needed to diagnose a failure.

## Applying a proposal

Gitly accepts bounded unified diffs for regular text files. The patch is checked against the selected commit in an isolated Git index before review and application. Binary changes, file mode changes, symlinks, submodules, and unsafe file paths are rejected. Gitly AI does not execute model-generated shell commands or run repository tests in the web process.

Committing the fix checks source branch permissions and CI identity again and updates the branch only if it still points to the expected commit. Normal repository updates refresh file caches, pull request heads, and head-specific approvals. The fix does not merge or close the pull request.
