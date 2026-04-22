module main

import veb
import api
import json
import net.http
import os
import time

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
	callback := json.decode(CiStatusCallback, body) or {
		return ctx.json_error('Invalid request body')
	}

	repo_id := callback.repo_id.int()
	ci_run_id := callback.run_id.int()
	status := ci_status_from_string(callback.status)

	app.upsert_ci_status(repo_id, callback.commit_hash, callback.branch, status, ci_run_id) or {
		return ctx.json_error('Failed to update CI status: ${err}')
	}

	return ctx.json(api.ApiSuccessResponse[string]{
		success: true
		result:  'ok'
	})
}

// GET /:username/:repo_name/ci - CI runs list page
@['/:username/:repo_name/ci']
pub fn (mut app App) ci_runs(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !repo.is_public {
		if repo.user_id != ctx.user.id {
			return ctx.not_found()
		}
	}

	// Check if .gitly-ci.yml exists in the repo
	has_ci_file := os.execute('git -C ${repo.git_dir} show ${repo.primary_branch}:.gitly-ci.yml').exit_code == 0

	// Fetch runs from gitly_ci service for a complete list
	mut ci_runs := []CiRunListItem{}
	mut ci_service_error := false
	if app.config.ci_service_url != '' {
		runs_url := '${app.config.ci_service_url}/api/v1/runs/repo/${repo.id}'
		response := http.get(runs_url) or {
			ci_service_error = true
			http.Response{}
		}
		if !ci_service_error && response.status_code == 200 {
			runs_resp := json.decode(CiApiRunListResponse, response.body) or {
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
pub fn (mut app App) ci_run_detail(username string, repo_name string, run_id_str string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !repo.is_public {
		if repo.user_id != ctx.user.id {
			return ctx.not_found()
		}
	}

	ci_run_id := run_id_str.int()

	// Fetch run details from gitly_ci service
	if app.config.ci_service_url == '' {
		return ctx.not_found()
	}

	ci_url := '${app.config.ci_service_url}/api/v1/runs/${ci_run_id}'
	response := http.get(ci_url) or {
		return ctx.not_found()
	}

	if response.status_code != 200 {
		return ctx.not_found()
	}

	ci_run_json := response.body

	// Parse the response to display
	run_data := json.decode(CiApiRunResponse, ci_run_json) or {
		return ctx.not_found()
	}

	ci_run := run_data.result

	return $veb.html()
}

// POST /:username/:repo_name/ci/:run_id_str/restart - Restart a CI run
@['/:username/:repo_name/ci/:run_id_str/restart'; post]
pub fn (mut app App) ci_restart_run(username string, repo_name string, run_id_str string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	// Only repo owner can restart
	if repo.user_id != ctx.user.id {
		return ctx.not_found()
	}

	ci_run_id := run_id_str.int()

	if app.config.ci_service_url == '' {
		return ctx.not_found()
	}

	// Call gitly_ci restart API
	restart_url := '${app.config.ci_service_url}/api/v1/runs/${ci_run_id}/restart'
	response := http.post(restart_url, '') or {
		return ctx.not_found()
	}

	if response.status_code != 200 {
		return ctx.not_found()
	}

	result := json.decode(CiApiRunResponse, response.body) or {
		return ctx.not_found()
	}

	if result.success {
		new_run := result.result
		// Update local CI status
		app.upsert_ci_status(repo.id, new_run.commit_hash, new_run.branch, .pending, new_run.id) or {}
		// Redirect to new run
		return ctx.redirect('/${username}/${repo_name}/ci/${new_run.id}')
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
	id          int
	status      string
	commit_hash string
	branch      string
	created_at  int
	finished_at int
	jobs        []CiJobDetail
}

struct CiJobDetail {
	id          int
	name        string
	status      string
	exit_code   int
	started_at  int
	finished_at int
	steps       []CiStepDetail
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
		else { 'ci-pending' }
	}
}

fn (s &CiStepDetail) status_css_class() string {
	return match s.status {
		'success' { 'ci-success' }
		'failure' { 'ci-failure' }
		'running' { 'ci-running' }
		'cancelled' { 'ci-cancelled' }
		else { 'ci-pending' }
	}
}

fn (s &CiStepDetail) status_icon() string {
	return match s.status {
		'success' { '✓' }
		'failure' { '✗' }
		'running' { '⟳' }
		'cancelled' { '⊘' }
		else { '○' }
	}
}
