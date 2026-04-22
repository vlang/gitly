module main

import json
import net.http
import os

struct CiTriggerPayload {
	repo_id      int
	commit_hash  string
	branch       string
	repo_path    string
	yaml_config  string
	callback_url string
}

struct CiTriggerResponse {
	success bool
	result  CiTriggerResult
}

struct CiTriggerResult {
	id     int
	status string
}

// trigger_ci_if_configured checks if the repo has a .gitly-ci.yml and triggers a CI run
fn (mut app App) trigger_ci_if_configured(repo_id int, branch_name string) {
	repo := app.find_repo_by_id(repo_id) or { return }

	if app.config.ci_service_url == '' {
		return
	}

	// Read .gitly-ci.yml from the repo using git show (works with bare repos)
	show_result := os.execute('git -C ${repo.git_dir} show ${branch_name}:.gitly-ci.yml')
	if show_result.exit_code != 0 || show_result.output.trim_space() == '' {
		app.info('No .gitly-ci.yml found in ${repo.name}/${branch_name}')
		return
	}
	yaml_config := show_result.output

	app.info('Found .gitly-ci.yml in ${repo.name}/${branch_name}, triggering CI')
	app.send_ci_trigger(repo, branch_name, yaml_config)
}

// trigger_ci_with_config triggers CI with a known YAML config (e.g. when the file was just created via web UI)
fn (mut app App) trigger_ci_with_config(repo_id int, branch_name string, yaml_config string) {
	repo := app.find_repo_by_id(repo_id) or { return }

	if app.config.ci_service_url == '' {
		return
	}

	app.info('Triggering CI for ${repo.name}/${branch_name} with provided config')
	app.send_ci_trigger(repo, branch_name, yaml_config)
}

fn (mut app App) send_ci_trigger(repo Repo, branch_name string, yaml_config string) {
	// Get the latest commit hash for this branch
	commit_hash := repo.get_last_branch_commit_hash(branch_name)

	// Build callback URL
	callback_url := 'http://localhost:${app.port}/api/v1/ci/status'

	// Get the absolute path to the git directory
	repo_path := os.real_path(repo.git_dir)

	payload := json.encode(CiTriggerPayload{
		repo_id:      repo.id
		commit_hash:  commit_hash
		branch:       branch_name
		repo_path:    repo_path
		yaml_config:  yaml_config
		callback_url: callback_url
	})

	// Record pending status
	app.upsert_ci_status(repo.id, commit_hash, branch_name, .pending, 0) or {
		app.warn('Failed to create CI status: ${err}')
	}

	// Trigger CI service
	ci_url := '${app.config.ci_service_url}/api/v1/trigger'
	app.info('Posting CI trigger to ${ci_url}')

	response := http.post_json(ci_url, payload) or {
		app.warn('Failed to trigger CI: ${err}')
		return
	}

	if response.status_code == 200 {
		result := json.decode(CiTriggerResponse, response.body) or {
			app.warn('Failed to parse CI trigger response')
			return
		}
		if result.success {
			app.upsert_ci_status(repo.id, commit_hash, branch_name, .pending, result.result.id) or {
				app.warn('Failed to update CI status with run id')
			}
			app.info('CI run ${result.result.id} triggered for ${repo.name}')
		}
	} else {
		app.warn('CI trigger returned status ${response.status_code}: ${response.body}')
	}
}
