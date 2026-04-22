module main

import time

enum CiStatusEnum {
	pending   = 0
	running   = 1
	success   = 2
	failure   = 3
	cancelled = 4
}

fn (s CiStatusEnum) str() string {
	return match s {
		.pending { 'pending' }
		.running { 'running' }
		.success { 'success' }
		.failure { 'failure' }
		.cancelled { 'cancelled' }
	}
}

fn (s CiStatusEnum) css_class() string {
	return match s {
		.pending { 'ci-pending' }
		.running { 'ci-running' }
		.success { 'ci-success' }
		.failure { 'ci-failure' }
		.cancelled { 'ci-cancelled' }
	}
}

fn (s CiStatusEnum) icon() string {
	return match s {
		.pending { '⏳' }
		.running { '🔄' }
		.success { '✓' }
		.failure { '✗' }
		.cancelled { '⊘' }
	}
}

struct CiStatus {
	id          int    @[primary; sql: serial]
	repo_id     int
	commit_hash string
	branch      string
	status      CiStatusEnum
	ci_run_id   int
	created_at  int
	updated_at  int
}

fn ci_status_from_string(s string) CiStatusEnum {
	return match s {
		'pending' { CiStatusEnum.pending }
		'running' { CiStatusEnum.running }
		'success' { CiStatusEnum.success }
		'failure' { CiStatusEnum.failure }
		'cancelled' { CiStatusEnum.cancelled }
		else { CiStatusEnum.pending }
	}
}

fn (mut app App) find_ci_status_for_commit(repo_id int, commit_hash string) ?CiStatus {
	results := sql app.db {
		select from CiStatus where repo_id == repo_id && commit_hash == commit_hash order by id desc limit 1
	} or { return none }
	if results.len == 0 {
		return none
	}
	return results[0]
}

fn (mut app App) find_ci_status_for_branch(repo_id int, branch string) ?CiStatus {
	results := sql app.db {
		select from CiStatus where repo_id == repo_id && branch == branch order by id desc limit 1
	} or { return none }
	if results.len == 0 {
		return none
	}
	return results[0]
}

fn (mut app App) find_ci_runs_for_repo(repo_id int) []CiStatus {
	return sql app.db {
		select from CiStatus where repo_id == repo_id order by id desc
	} or { []CiStatus{} }
}

fn (mut app App) add_ci_status(ci CiStatus) ! {
	sql app.db {
		insert ci into CiStatus
	}!
}

fn (mut app App) update_ci_status(repo_id int, commit_hash string, status CiStatusEnum) ! {
	updated := int(time.now().unix())
	sql app.db {
		update CiStatus set status = status, updated_at = updated where repo_id == repo_id && commit_hash == commit_hash
	}!
}

fn (mut app App) upsert_ci_status(repo_id int, commit_hash string, branch string, status CiStatusEnum, ci_run_id int) ! {
	existing := app.find_ci_status_for_commit(repo_id, commit_hash) or {
		// Insert new
		app.add_ci_status(CiStatus{
			repo_id:     repo_id
			commit_hash: commit_hash
			branch:      branch
			status:      status
			ci_run_id:   ci_run_id
			created_at:  int(time.now().unix())
			updated_at:  int(time.now().unix())
		})!
		return
	}
	// Update existing
	id := existing.id
	updated := int(time.now().unix())
	sql app.db {
		update CiStatus set status = status, ci_run_id = ci_run_id, updated_at = updated where id == id
	}!
}

fn (mut app App) delete_repo_ci_statuses(repo_id int) ! {
	sql app.db {
		delete from CiStatus where repo_id == repo_id
	}!
}

fn (ci &CiStatus) relative_time() string {
	if ci.updated_at == 0 && ci.created_at == 0 {
		return ''
	}
	t := if ci.updated_at > 0 { ci.updated_at } else { ci.created_at }
	return time.unix(t).relative()
}
