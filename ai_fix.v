// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import crypto.hmac
import crypto.sha256
import encoding.hex
import encoding.utf8
import git
import os
import time
import x.json2 as json

struct AiFixContext {
	repo        Repo
	pr          PullRequest
	source_repo Repo
	head_oid    string
	ci_status   CiStatus
}

struct AiFixSourceFile {
	path    string
	content string
}

struct AiFixPrompt {
	repository    string
	pull_request  int
	title         string
	description   string
	source_branch string
	head_oid      string
	ci_run_id     int
	failed_logs   string
	diff          string
	files         []AiFixSourceFile
}

fn (mut app App) ai_fix_source_repo(user_id int, repo Repo, pr PullRequest) !Repo {
	if pr.repo_id != repo.id || !app.user_has_repo_read_access(user_id, repo) {
		return error('Pull request is not accessible')
	}
	source_id := if pr.head_repo_id > 0 { pr.head_repo_id } else { repo.id }
	source := app.find_repo_by_id(source_id) or {
		return error('The source repository no longer exists')
	}
	if !app.user_has_repo_read_access(user_id, source)
		|| !app.repos_share_fork_network(repo.id, source.id) {
		return error('The source repository is not accessible')
	}
	return source
}

fn ai_fix_head_oid(source Repo, pr PullRequest) !string {
	if !is_safe_ref(pr.head_branch) {
		return error('Invalid source branch')
	}
	head_oid := git_rev_parse(source.git_dir, 'refs/heads/${pr.head_branch}') or {
		return error('The source branch no longer exists')
	}
	if !is_full_commit_oid(head_oid) {
		return error('Invalid source commit')
	}
	return head_oid
}

// CI belongs to the actual source branch, including for cross-fork requests.
// Never fall back to a previous commit or the target's possibly stale PR ref.
fn (mut app App) pull_request_ci_status(user_id int, repo Repo, pr PullRequest) ?CiStatus {
	source := app.ai_fix_source_repo(user_id, repo, pr) or { return none }
	head_oid := ai_fix_head_oid(source, pr) or { return none }
	return app.find_ci_status_for_commit(source.id, head_oid, pr.head_branch)
}

fn (mut app App) ai_fix_context(user_id int, repo Repo, pr PullRequest) !AiFixContext {
	source := app.ai_fix_source_repo(user_id, repo, pr)!
	if user_id <= 0 || !pr.is_open() || !is_safe_ref(pr.base_branch)
		|| (source.id == repo.id && pr.head_branch == pr.base_branch) {
		return error('AI fixes require an open pull request with a separate source branch')
	}
	if !app.user_can_push_branch(user_id, source, pr.head_branch) {
		return error('You are not allowed to push to the source branch')
	}
	if source.require_signed_commits {
		return error('AI commits are disabled because the source project requires user-signed commits')
	}
	if app.config.ci_service_url.trim_space() == '' || app.config.ci_secret == '' {
		return error('Authenticated CI integration is not configured')
	}
	head_oid := ai_fix_head_oid(source, pr)!
	ci := app.find_ci_status_for_commit(source.id, head_oid, pr.head_branch) or {
		return error('No CI run exists for the current source commit')
	}
	if ci.status !in [.failure, .timed_out] || ci.ci_run_id <= 0 {
		return error('The latest CI run for this commit has not failed')
	}
	bound := app.find_ci_status_for_run(source.id, ci.ci_run_id) or {
		return error('The failed CI run has no unique repository binding')
	}
	if bound.id != ci.id {
		return error('The failed CI run has changed')
	}
	return AiFixContext{
		repo:        repo
		pr:          pr
		source_repo: source
		head_oid:    head_oid
		ci_status:   ci
	}
}

fn (mut app App) can_ai_fix_pull_request(user_id int, repo Repo, pr PullRequest) bool {
	app.ai_fix_context(user_id, repo, pr) or { return false }
	return true
}

fn ai_fix_ci_run_matches(ci CiStatus, run CiRunDetail) bool {
	return ci.id > 0 && ci.ci_run_id > 0 && ci.status in [.failure, .timed_out]
		&& run.id == ci.ci_run_id && run.status == ci.status.str()
		&& is_full_commit_oid(ci.commit_hash) && run.commit_hash == ci.commit_hash
		&& is_safe_ref(ci.branch) && run.branch == ci.branch
}

// Bind both POSTs to this authenticated session and PR. The CI secret is
// already required for this feature; no additional persisted secret is needed.
fn ai_fix_csrf_token(secret string, session_token string, repo_id int, pr_id int) string {
	if secret == '' || session_token == '' || repo_id <= 0 || pr_id <= 0 {
		return ''
	}
	payload := 'gitly-ai-form\n${hash_session_token(session_token)}\n${repo_id}\n${pr_id}'
	return hex.encode(hmac.new(secret.bytes(), payload.bytes(), sha256.sum, sha256.block_size))
}

fn ai_fix_trim_text(value string, limit int) string {
	if value.len <= limit {
		return value
	}
	mut end := limit
	// Do not split a UTF-8 sequence at a context boundary.
	for end > 0 && (value[end] & 0xc0) == 0x80 {
		end--
	}
	return value[..end] + '\n[truncated]'
}

fn ai_fix_failed_logs(run CiRunDetail) string {
	mut logs := ai_fix_trim_text(run.error_message, 4096)
	for job in run.jobs {
		for step in job.steps {
			if step.status !in ['failure', 'timed_out'] && step.exit_code == 0 {
				continue
			}
			logs += '\nJob: ${job.name}\nStep: ${step.name}\nCommand: ${step.command}\nExit code: ${step.exit_code}\n'
			// The tail generally contains the failure when a build log is long.
			output := if step.output.len > 12 * 1024 {
				mut start := step.output.len - 12 * 1024
				for start < step.output.len && (step.output[start] & 0xc0) == 0x80 {
					start++
				}
				'[earlier output omitted]\n' + step.output[start..]
			} else {
				step.output
			}
			logs += output
			if logs.len >= 32 * 1024 {
				return ai_fix_trim_text(logs, 32 * 1024)
			}
		}
	}
	return ai_fix_trim_text(logs, 32 * 1024)
}

// Stop Git as soon as enough context is available instead of first allocating
// an entire large PR diff or filename list in the web process.
fn ai_fix_read_git_context(repo Repo, args []string, limit int) !string {
	mut process := os.new_process('git')
	mut command := ['-C', repo.git_dir, '-c', 'core.fsmonitor=false']
	command << args
	process.set_args(command)
	process.set_redirect_stdio_merged()
	process.run()
	defer { process.close() }
	mut output := ''
	started := time.ticks()
	for {
		alive := process.is_alive()
		chunk := process.stdout_read()
		if output.len + chunk.len > limit {
			output += chunk[..limit + 1 - output.len]
			process.signal_kill()
			process.wait()
			return output
		}
		output += chunk
		if !alive && chunk == '' {
			break
		}
		if time.ticks() - started > 15_000 {
			process.signal_kill()
			process.wait()
			return error('Reading the pull request context timed out')
		}
		if chunk == '' {
			time.sleep(time.millisecond)
		}
	}
	process.wait()
	if process.code != 0 {
		return error('Could not read the pull request changes')
	}
	return output
}

// Read regular text blobs directly, without a checkout, filters or textconv.
fn ai_fix_source_file(repo Repo, head_oid string, path string) ?AiFixSourceFile {
	if !ai_fix_safe_path(path) {
		return none
	}
	entry := git.Git.exec_in_dir(repo.git_dir, ['ls-tree', '-z', head_oid, '--', ':(literal)${path}'])
	if entry.exit_code != 0 || entry.output.count('\x00') != 1 {
		return none
	}
	metadata := entry.output.all_before('\t').fields()
	if metadata.len != 3 || metadata[0] !in ['100644', '100755'] || metadata[1] != 'blob'
		|| entry.output.all_after('\t').trim_right('\x00') != path {
		return none
	}
	size := git.Git.exec_in_dir(repo.git_dir, ['cat-file', '-s', metadata[2]])
	blob_size := size.output.trim_space().i64()
	if size.exit_code != 0 || blob_size < 0 || blob_size > 16 * 1024 {
		return none
	}
	blob := git.Git.exec_in_dir(repo.git_dir, ['cat-file', 'blob', metadata[2]])
	if blob.exit_code != 0 || blob.output.contains('\x00') || blob.output.len > 16 * 1024
		|| !utf8.validate_str(blob.output) {
		return none
	}
	return AiFixSourceFile{ path: path, content: blob.output }
}

fn (mut app App) ai_fix_prompt(state AiFixContext) !string {
	response := app.ci_service_request_limited(.get, '/api/v1/runs/${state.ci_status.ci_run_id}', '',
		2 * 1024 * 1024) or {
		return error('Could not retrieve the failed CI run')
	}
	if response.status_code != 200 || response.body.len > 2 * 1024 * 1024 {
		return error('CI run details are unavailable or too large')
	}
	decoded := json.decode[CiApiRunResponse](response.body) or {
		return error('CI service returned invalid run details')
	}
	if !decoded.success || !ai_fix_ci_run_matches(state.ci_status, decoded.result) {
		return error('CI service returned details for a different run or commit')
	}
	app.refresh_cross_fork_pr_head(state.repo, state.pr) or {
		return error('Could not refresh the source fork for this pull request')
	}
	cached_head := app.pull_request_head_oid(state.pr) or { '' }
	if cached_head != state.head_oid {
		return error('The source branch changed. Reload the pull request and try again')
	}
	base_oid := git_rev_parse(state.repo.git_dir, 'refs/heads/${state.pr.base_branch}') or {
		return error('The target branch no longer exists')
	}
	if !is_full_commit_oid(base_oid) {
		return error('Invalid target commit')
	}
	range := '${base_oid}...${state.head_oid}'
	diff := ai_fix_read_git_context(state.repo, ['diff', '--no-ext-diff', '--no-textconv', '--no-color',
		'--no-renames', '--src-prefix=a/', '--dst-prefix=b/', range, '--'], 48 * 1024)!
	names := ai_fix_read_git_context(state.repo, ['diff', '--name-only', '-z', '--no-renames',
		range, '--'], 32 * 1024)!
	logs := ai_fix_failed_logs(decoded.result)
	mut paths := ['.gitly-ci.yml']
	// Prefer file paths mentioned by diagnostics, then the PR's changed files.
	for word in logs.fields() {
		path := word.trim('"\'`()[],;').all_before(':').trim_left('./')
		if path.contains('.') && ai_fix_safe_path(path) && path !in paths && paths.len < 80 {
			paths << path
		}
	}
	for path in names.all_before_last('\x00').split('\x00') {
		if ai_fix_safe_path(path) && path !in paths && paths.len < 120 {
			paths << path
		}
	}
	mut files := []AiFixSourceFile{}
	mut bytes := 0
	for path in paths {
		file := ai_fix_source_file(state.source_repo, state.head_oid, path) or { continue }
		if bytes + file.content.len > 64 * 1024 || files.len >= 12 {
			continue
		}
		bytes += file.content.len
		files << file
	}
	prompt := json.encode(AiFixPrompt{
		repository:    '${state.repo.user_name}/${state.repo.name}'
		pull_request:  state.pr.id
		title:         ai_fix_trim_text(state.pr.title, 512)
		description:   ai_fix_trim_text(state.pr.description, 4096)
		source_branch: state.pr.head_branch
		head_oid:      state.head_oid
		ci_run_id:     state.ci_status.ci_run_id
		failed_logs:   logs
		diff:          ai_fix_trim_text(diff, 48 * 1024)
		files:         files
	})
	if prompt.len > 256 * 1024 {
		return error('The selected CI and source context is too large')
	}
	if !utf8.validate_str(prompt) {
		return error('CI logs or source changes contain unsupported text encoding')
	}
	return prompt
}
