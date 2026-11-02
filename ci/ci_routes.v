module main

import veb
import api
import x.json2 as json
import net.http
import time
import git
import crypto.hmac
import crypto.sha256
import encoding.hex
import os

struct CiStatusCallback {
	run_id      string
	repo_id     string
	commit_hash string
	branch      string
	status      string
}

// POST /api/v1/ci/status - Callback endpoint for gitly_ci to report status updates
@['/api/v1/ci/status'; post]
pub fn (mut app App) handle_ci_status_callback() veb.Result {
	body := ctx.req.data
	if !app.verify_ci_callback_signature(ctx, body) {
		ctx.res.set_status(.unauthorized)
		return ctx.json_error('Invalid or missing CI callback signature')
	}
	callback := json.decode[CiStatusCallback](body) or {
		ctx.res.set_status(.bad_request)
		return ctx.json_error('Invalid request body')
	}

	repo_id := callback.repo_id.int()
	ci_run_id := callback.run_id.int()
	if repo_id <= 0 || ci_run_id <= 0 || !is_full_commit_oid(callback.commit_hash)
		|| !is_safe_ref(callback.branch)
		|| callback.status !in ['pending', 'running', 'success', 'failure', 'cancelled', 'timed_out'] {
		ctx.res.set_status(.bad_request)
		return ctx.json_error('Invalid CI status payload')
	}
	app.find_repo_by_id(repo_id) or {
		ctx.res.set_status(.not_found)
		return ctx.json_error('Repository not found')
	}
	status := ci_status_from_string(callback.status)

	applied := app.apply_ci_status_callback_after_registration(repo_id, callback.commit_hash,
		callback.branch, ci_run_id, status) or {
		ctx.res.set_status(.internal_server_error)
		return ctx.json_error('Failed to update CI status: ${err}')
	}
	if !applied {
		// A very fast run can report status before the trigger HTTP response has
		// supplied its run id. Ask the runner to retry while that local
		// reservation exists; applying an unknown id to it would let a stale
		// callback claim a newer attempt.
		if app.has_ci_status_reservation(repo_id, callback.commit_hash, callback.branch) {
			ctx.res.set_status(.conflict)
			return ctx.json_error('CI run registration is still pending')
		}
		// A validly signed callback can still arrive after a newer attempt or for
		// a run that Gitly never successfully registered. Acknowledge it so the
		// runner does not retry forever, but never let it create or replace state.
		app.warn('Ignored CI callback for unknown run ${ci_run_id} in repository ${repo_id}')
		return ctx.json(api.ApiSuccessResponse[string]{
			success: true
			result:  'ignored'
		})
	}

	return ctx.json(api.ApiSuccessResponse[string]{
		success: true
		result:  'ok'
	})
}

// verify_ci_callback_signature checks the HMAC-SHA256 signature of the raw
// callback body against the shared ci_secret, using a constant-time compare.
// An unset secret fails closed. Configure ci_secret or GITLY_CI_SECRET in both
// services; accepting unsigned status changes lets anyone spoof a successful
// build for any repository.
fn (mut app App) verify_ci_callback_signature(ctx &Context, body string) bool {
	env_secret := os.getenv('GITLY_CI_SECRET')
	secret := if env_secret != '' { env_secret } else { app.config.ci_secret }
	if secret == '' {
		app.warn('CI status callback rejected: configure ci_secret or GITLY_CI_SECRET')
		return false
	}
	provided := ctx.get_custom_header('X-Gitly-CI-Signature') or { return false }
	mac := hmac.new(secret.bytes(), body.bytes(), sha256.sum, sha256.block_size)
	expected := 'sha256=' + hex.encode(mac)
	return hmac.equal(provided.bytes(), expected.bytes())
}

// GET /:username/:repo_name/ci - CI runs list page
@['/:username/:repo_name/ci']
pub fn (mut app App) ci_runs(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}

	// Check if .gitly-ci.yml exists in the repo
	has_ci_file := git.Git.exec_in_dir(repo.git_dir,
		['show', '${repo.primary_branch}:.gitly-ci.yml']).exit_code == 0

	// Fetch runs from gitly_ci service for a complete list
	mut ci_runs := []CiRunListItem{}
	mut ci_service_error := false
	if app.config.ci_service_url != '' {
		response := app.ci_service_request(.get, '/api/v1/runs/repo/${repo.id}', '') or {
			ci_service_error = true
			http.Response{}
		}
		if !ci_service_error && response.status_code == 200 {
			runs_resp := json.decode[CiApiRunListResponse](response.body) or {
				CiApiRunListResponse{}
			}
			if runs_resp.success {
				for r in runs_resp.result {
					ci_runs << CiRunListItem{
						ci_run_id:   r.id
						status:      ci_status_from_string(r.status)
						commit_hash: r.commit_hash
						branch:      r.branch
						created_at:  r.created_at
						finished_at: r.finished_at
					}
				}
			}
		} else if !ci_service_error && response.status_code != 200 {
			ci_service_error = true
		}
	}

	return $veb.html()
}

// GET /:username/:repo_name/ci/:run_id_str - CI run detail page
@['/:username/:repo_name/ci/:run_id_str']
pub fn (mut app App) ci_run_detail(mut ctx Context, username string, repo_name string, run_id_str string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}

	ci_run_id := run_id_str.int()
	if !app.repo_owns_ci_run(repo.id, ci_run_id) {
		return ctx.not_found()
	}

	// Fetch run details from gitly_ci service
	if app.config.ci_service_url == '' {
		return ctx.not_found()
	}

	response := app.ci_service_request(.get, '/api/v1/runs/${ci_run_id}', '') or {
		return ctx.not_found()
	}

	if response.status_code != 200 {
		return ctx.not_found()
	}

	ci_run_json := response.body

	// Parse the response to display
	run_data := json.decode[CiApiRunResponse](ci_run_json) or { return ctx.not_found() }

	ci_run := run_data.result

	return $veb.html()
}

// POST /:username/:repo_name/ci/:run_id_str/restart - Restart a CI run
@['/:username/:repo_name/ci/:run_id_str/restart'; post]
pub fn (mut app App) ci_restart_run(mut ctx Context, username string, repo_name string, run_id_str string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}

	ci_run_id := run_id_str.int()
	source_run := app.find_ci_status_for_run(repo.id, ci_run_id) or { return ctx.not_found() }

	if app.config.ci_service_url == '' {
		return ctx.not_found()
	}

	response := app.ci_service_request(.post, '/api/v1/runs/${ci_run_id}/restart', '') or {
		return ctx.not_found()
	}

	if response.status_code != 200 {
		return ctx.not_found()
	}

	result := json.decode[CiApiRunResponse](response.body) or { return ctx.not_found() }

	if result.success {
		new_run := result.result
		if !ci_restart_result_matches(source_run, new_run) {
			app.warn('Rejected mismatched CI restart response for run ${ci_run_id}')
			return ctx.server_error('CI restart response could not be verified')
		}
		app.upsert_ci_status(repo.id, new_run.commit_hash, new_run.branch, .pending, new_run.id) or {
			app.warn('Could not bind restarted CI run ${new_run.id}: ${err}')
			return ctx.server_error('CI restart response could not be registered')
		}
		// Redirect to new run
		return ctx.redirect('/${username}/${repo_name}/ci/${new_run.id}')
	}

	return ctx.redirect('/${username}/${repo_name}/ci/${ci_run_id}')
}

// POST /:username/:repo_name/ci/:run_id_str/cancel - Cancel a CI run.
@['/:username/:repo_name/ci/:run_id_str/cancel'; post]
pub fn (mut app App) ci_cancel_run(mut ctx Context, username string, repo_name string, run_id_str string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	ci_run_id := run_id_str.int()
	if !app.repo_owns_ci_run(repo.id, ci_run_id) || app.config.ci_service_url == '' {
		return ctx.not_found()
	}
	response := app.ci_service_request(.post, '/api/v1/runs/${ci_run_id}/cancel', '') or {
		return ctx.not_found()
	}
	if response.status_code != 200 {
		return ctx.not_found()
	}
	return ctx.redirect('/${username}/${repo_name}/ci/${ci_run_id}')
}

// Structs for parsing gitly_ci API responses

struct CiApiRunListResponse {
	success bool
	result  []CiRunListResponseItem
}

struct CiRunListResponseItem {
	id          int
	status      string
	commit_hash string
	branch      string
	created_at  int
	finished_at int
}

struct CiRunListItem {
	ci_run_id   int
	status      CiStatusEnum
	commit_hash string
	branch      string
	created_at  int
	finished_at int
}

fn (ci &CiRunListItem) relative_time() string {
	if ci.finished_at > 0 {
		return time.unix(ci.finished_at).relative()
	}
	if ci.created_at > 0 {
		return time.unix(ci.created_at).relative()
	}
	return ''
}

struct CiApiRunResponse {
	success bool
	result  CiRunDetail
}

struct CiRunDetail {
	id            int
	status        string
	commit_hash   string
	branch        string
	created_at    int
	started_at    int
	finished_at   int
	error_message string
	jobs          []CiJobDetail
}

fn ci_restart_result_matches(source CiStatus, restarted CiRunDetail) bool {
	return source.id > 0 && source.ci_run_id > 0 && restarted.id > 0
		&& restarted.id != source.ci_run_id && is_full_commit_oid(source.commit_hash)
		&& is_full_commit_oid(restarted.commit_hash) && restarted.commit_hash == source.commit_hash
		&& is_safe_ref(restarted.branch) && restarted.branch == source.branch
}

struct CiJobDetail {
	id            int
	name          string
	stage         string
	status        string
	allow_failure bool
	exit_code     int
	started_at    int
	finished_at   int
	steps         []CiStepDetail
}

struct CiStepDetail {
	id        int
	name      string
	command   string
	status    string
	output    string
	exit_code int
}

fn (r &CiRunDetail) status_css_class() string {
	return match r.status {
		'success' { 'ci-success' }
		'failure' { 'ci-failure' }
		'running' { 'ci-running' }
		'cancelled' { 'ci-cancelled' }
		'timed_out' { 'ci-failure' }
		else { 'ci-pending' }
	}
}

fn (r &CiRunDetail) created_relative() string {
	if r.created_at == 0 {
		return ''
	}
	return time.unix(r.created_at).relative()
}

fn (r &CiRunDetail) duration() string {
	if r.finished_at == 0 || r.created_at == 0 {
		return 'running...'
	}
	d := r.finished_at - r.created_at
	if d < 60 {
		return '${d}s'
	}
	return '${d / 60}m ${d % 60}s'
}

fn (j &CiJobDetail) status_css_class() string {
	return match j.status {
		'success' { 'ci-success' }
		'failure' { 'ci-failure' }
		'running' { 'ci-running' }
		'cancelled' { 'ci-cancelled' }
		'timed_out' { 'ci-failure' }
		'skipped' { 'ci-pending' }
		else { 'ci-pending' }
	}
}

fn (s &CiStepDetail) status_css_class() string {
	return match s.status {
		'success' { 'ci-success' }
		'failure' { 'ci-failure' }
		'running' { 'ci-running' }
		'cancelled' { 'ci-cancelled' }
		'timed_out' { 'ci-failure' }
		'skipped' { 'ci-pending' }
		else { 'ci-pending' }
	}
}

fn (s &CiStepDetail) status_icon() string {
	return match s.status {
		'success' { '✓' }
		'failure' { '✗' }
		'running' { '⟳' }
		'cancelled' { '⊘' }
		'timed_out' { '⌛' }
		'skipped' { '–' }
		else { '○' }
	}
}
