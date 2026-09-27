module main

import config
import git
import highlight
import json2
import os
import rand
import time
import veb

const loc_week_seconds = 7 * 24 * 60 * 60
const loc_monday_offset = 4 * 24 * 60 * 60
const loc_stale_seconds = 60 * 60
const loc_excluded_directories = '.git,.hg,.svn,3rdparty,thirdparty,3rd_party,third_party,3rd-party,third-party,vendor,vendors'

struct LocHistoryJob {
	id            int @[primary; sql: serial]
	repo_id       int
	status        string
	branch        string
	head_oid      string
	total         int
	completed     int
	error_message string
	updated_at    int
}

struct LocHistorySnapshot {
	id         int @[primary; sql: serial]
	repo_id    int
	week_start int
	commit_oid string
	total_code int
}

struct LocHistoryLanguage {
	id          int @[primary; sql: serial]
	snapshot_id int
	name        string
	code        int
}

struct SccLocLanguage {
	name string @[json: 'Name']
	code int    @[json: 'Code']
}

struct LocCommit {
	committed_at int
	oid          string
}

struct LocWeek {
	week_start int
	oid        string
}

struct LocHistoryResponse {
	job       LocHistoryJob
	snapshots []LocHistorySnapshot
	languages []LocHistoryLanguage
	colors    map[string]string
}

fn loc_week_start(timestamp int) int {
	return (timestamp - loc_monday_offset) / loc_week_seconds * loc_week_seconds + loc_monday_offset
}

fn weekly_loc_revisions(log_output string, through_timestamp int) ![]LocWeek {
	mut commits := []LocCommit{}
	mut latest_time := 0
	for line in log_output.split_into_lines() {
		parts := line.split('\t')
		if parts.len != 2 || parts[0] == '' || parts[1].len < 40 {
			return error('invalid git history entry')
		}
		committed_at := parts[0].int()
		// Keep ancestry order even when a commit's clock is behind its parent.
		if committed_at > latest_time {
			latest_time = committed_at
		}
		commits << LocCommit{
			committed_at: latest_time
			oid:          parts[1]
		}
	}
	if commits.len == 0 {
		return []LocWeek{}
	}
	// The log is in first-parent ancestry order. Its effective timestamps are
	// monotonic so the final weekly revision is always the branch tip.
	mut weeks := []LocWeek{}
	mut index := 0
	mut latest_oid := ''
	mut week := loc_week_start(commits[0].committed_at)
	last_timestamp := if through_timestamp > commits.last().committed_at {
		through_timestamp
	} else {
		commits.last().committed_at
	}
	last_week := loc_week_start(last_timestamp)
	for week <= last_week {
		for index < commits.len && commits[index].committed_at < week + loc_week_seconds {
			latest_oid = commits[index].oid
			index++
		}
		if latest_oid != '' {
			weeks << LocWeek{
				week_start: week
				oid:        latest_oid
			}
		}
		week += loc_week_seconds
	}
	return weeks
}

fn (mut app App) find_loc_history_job(repo_id int) LocHistoryJob {
	rows := sql app.db {
		select from LocHistoryJob where repo_id == repo_id limit 1
	} or { return LocHistoryJob{} }
	return if rows.len == 1 { rows[0] } else { LocHistoryJob{} }
}

fn (mut app App) queue_loc_history(repo_id int) !bool {
	now := time.now().unix().str()
	stale_before := (time.now().unix() - loc_stale_seconds).str()
	rows := db_exec_param_values(mut app.db,
		"insert into ${sql_table('LocHistoryJob')} (repo_id, status, branch, head_oid, total, completed, error_message, updated_at) values (${db_parameter_marker(0)}, 'queued', '', '', 0, 0, '', ${db_parameter_marker(1)}) on conflict(repo_id) do update set status = 'queued', total = 0, completed = 0, error_message = '', updated_at = excluded.updated_at where status in ('done', 'failed') or (status = 'running' and updated_at < ${db_parameter_marker(2)}) returning id",
		[repo_id.str(), now, stale_before])!
	return rows.len == 1
}

fn (mut app App) loc_job_update(repo_id int, status string, total int, completed int, message string) ! {
	updated_at := time.now().unix()
	error_message := message
	sql app.db {
		update LocHistoryJob set status = status, total = total, completed = completed,
		error_message = error_message, updated_at = updated_at where repo_id == repo_id
	}!
}

fn merge_loc_languages(languages []SccLocLanguage) []SccLocLanguage {
	mut counts := map[string]int{}
	for language in languages {
		if language.code <= 0 || language.name == '' || language.name in ['Markdown', 'Plain Text'] {
			continue
		}
		name := if language.name == 'C Header' { 'C' } else { language.name }
		counts[name] += language.code
	}
	mut merged := []SccLocLanguage{}
	for name, code in counts {
		merged << SccLocLanguage{
			name: name
			code: code
		}
	}
	return merged
}

fn loc_v_linguist_override(git_dir string, branch string) bool {
	attribute := git.Git.exec_in_dir(git_dir, ['check-attr', '--source', branch, 'linguist-language',
		'--', '.gitly-loc-probe.v'])
	return attribute.exit_code == 0 && attribute.output.trim_space().ends_with(': V')
}

fn (mut app App) save_loc_snapshot(repo_id int, week LocWeek, languages []SccLocLanguage) ! {
	merged := merge_loc_languages(languages)
	mut total := 0
	for language in merged {
		total += language.code
	}
	snapshot_id := db_insert_returning_id(mut app.db, 'LocHistorySnapshot', ['repo_id', 'week_start',
		'commit_oid', 'total_code'], [repo_id.str(), week.week_start.str(), week.oid, total.str()])!
	for language in merged {
		row := LocHistoryLanguage{
			snapshot_id: snapshot_id
			name:        language.name
			code:        language.code
		}
		sql app.db {
			insert row into LocHistoryLanguage
		}!
	}
}

fn (mut app App) calculate_loc_history(repo_id int) ! {
	repo := app.find_repo_by_id(repo_id) or { return error('repository no longer exists') }
	branch := repo.primary_branch
	v_linguist_override := loc_v_linguist_override(repo.git_dir, branch)
	log_result := git.Git.exec_in_dir(repo.git_dir, ['log', '--first-parent', '--reverse',
		'--format=%ct%x09%H', branch])
	if log_result.exit_code != 0 {
		eprintln('LOC history git log for repo ${repo_id}: ${log_result.output}')
		return error('could not read default branch history')
	}
	weeks := weekly_loc_revisions(log_result.output, int(time.now().unix()))!
	if weeks.len == 0 {
		return error('the default branch has no commits')
	}
	head_oid := weeks.last().oid
	total := weeks.len
	updated_at := time.now().unix()
	sql app.db {
		update LocHistoryJob set branch = branch, head_oid = head_oid, total = total,
		completed = 0, updated_at = updated_at where repo_id == repo_id
	}!
	// A retry starts a fresh cache. Readers only receive points after status=done.
	app.db.exec('delete from ${sql_table('LocHistoryLanguage')} where snapshot_id in (select id from ${sql_table('LocHistorySnapshot')} where repo_id = ${repo_id})')!
	app.db.exec('delete from ${sql_table('LocHistorySnapshot')} where repo_id = ${repo_id}')!

	workdir := os.join_path(os.temp_dir(), 'gitly_loc_${repo_id}_${rand.ulid()}')
	defer {
		os.rmdir_all(workdir) or {}
	}
	clone_result := git.Git.exec(['clone', '--local', '--no-hardlinks', '--no-checkout', '--quiet',
		repo.git_dir, workdir])
	if clone_result.exit_code != 0 {
		eprintln('LOC history clone for repo ${repo_id}: ${clone_result.output}')
		return error('could not create temporary checkout')
	}
	mut previous_oid := ''
	mut previous_languages := []SccLocLanguage{}
	for index, week in weeks {
		mut languages := previous_languages
		if week.oid != previous_oid {
			checkout := git.Git.exec_in_dir(workdir, ['checkout', '--force', '--detach', '--quiet',
				week.oid])
			if checkout.exit_code != 0 {
				eprintln('LOC history checkout for repo ${repo_id}: ${checkout.output}')
				return error('could not check out historical revision')
			}
			// The checkout only changes tracked files. Remove ignored/untracked
			// artifacts before scc counts this revision.
			clean := git.Git.exec_in_dir(workdir, ['clean', '-ffdx', '--quiet'])
			if clean.exit_code != 0 {
				eprintln('LOC history clean for repo ${repo_id}: ${clean.output}')
				return error('could not clean temporary checkout')
			}
			mut scc_args := ['scc', '--format', 'json', '--no-config', '--exclude-dir',
				loc_excluded_directories, '--exclude-ext', 'md,txt']
			if v_linguist_override {
				scc_args << '--count-as'
				scc_args << 'v:V'
			}
			scc_args << workdir
			measurement := os.exec(scc_args)
			if measurement.exit_code != 0 {
				eprintln('LOC history scc for repo ${repo_id}: ${measurement.output}')
				return error('scc failed; check that it is installed on the server')
			}
			languages = json2.decode[[]SccLocLanguage](measurement.output) or {
				eprintln('LOC history scc JSON for repo ${repo_id}: ${err}')
				return error('could not decode scc output')
			}
			previous_oid = week.oid
			previous_languages = languages.clone()
		}
		app.save_loc_snapshot(repo_id, week, languages)!
		app.loc_job_update(repo_id, 'running', total, index + 1, '')!
	}
	app.loc_job_update(repo_id, 'done', total, total, '')!
}

fn bg_calculate_loc_history(repo_id int, conf config.Config) {
	mut app := &App{
		db:     connect_db(conf) or {
			eprintln('LOC history: could not connect to database: ${err}')
			return
		}
		config: conf
	}
	defer {
		app.db.close() or {}
	}
	claimed := db_exec_param_values(mut app.db,
		"update ${sql_table('LocHistoryJob')} set status = 'running', updated_at = ${db_parameter_marker(0)} where repo_id = ${db_parameter_marker(1)} and status = 'queued' returning id",
		[time.now().unix().str(), repo_id.str()]) or {
		eprintln('LOC history: could not claim repo ${repo_id}: ${err}')
		return
	}
	if claimed.len == 0 {
		return
	}
	spawn loc_history_heartbeat(repo_id, conf)
	app.calculate_loc_history(repo_id) or {
		app.loc_job_update(repo_id, 'failed', app.find_loc_history_job(repo_id).total,
			app.find_loc_history_job(repo_id).completed, err.str().limit(500)) or {}
		eprintln('LOC history for repo ${repo_id}: ${err}')
	}
}

fn loc_history_heartbeat(repo_id int, conf config.Config) {
	mut db := connect_db(conf) or { return }
	defer {
		db.close() or {}
	}
	for {
		time.sleep(30 * time.second)
		rows := db_exec_param_values(mut db,
			"update ${sql_table('LocHistoryJob')} set updated_at = ${db_parameter_marker(0)} where repo_id = ${db_parameter_marker(1)} and status = 'running' returning id",
			[time.now().unix().str(), repo_id.str()]) or { return }
		if rows.len == 0 {
			return
		}
	}
}

fn resume_loc_history_jobs(conf config.Config) {
	for {
		resume_loc_history_jobs_once(conf)
		time.sleep(2 * time.second)
	}
}

fn resume_loc_history_jobs_once(conf config.Config) {
	mut db := connect_db(conf) or { return }
	stale_before := time.now().unix() - loc_stale_seconds
	db.exec("update ${sql_table('LocHistoryJob')} set status = 'queued' where status = 'running' and updated_at < ${stale_before}") or {}
	rows := db_exec_values(mut db, "select repo_id from ${sql_table('LocHistoryJob')} where status = 'queued' order by updated_at limit 1") or {
		db.close() or {}
		return
	}
	db.close() or {}
	if rows.len > 0 && rows[0].len > 0 {
		bg_calculate_loc_history(rows[0][0].int(), conf)
	}
}

@['/:username/:repo_name/loc']
pub fn (mut app App) repo_loc_history(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	can_run := app.can_admin_repo(ctx, repo)
	return $veb.html('templates/repo/loc_history.html')
}

@['/:username/:repo_name/loc'; post]
pub fn (mut app App) start_repo_loc_history(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	app.queue_loc_history(repo.id) or {
		ctx.error('Could not start LOC analysis: ${err}')
		return ctx.redirect('/${username}/${repo_name}/loc')
	}
	return ctx.redirect('/${username}/${repo_name}/loc')
}

@['/:username/:repo_name/loc/data']
pub fn (mut app App) repo_loc_history_data(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	job := app.find_loc_history_job(repo.id)
	mut snapshots := []LocHistorySnapshot{}
	mut languages := []LocHistoryLanguage{}
	mut colors := map[string]string{}
	if job.status == 'done' {
		repo_id := repo.id
		snapshots = sql app.db {
			select from LocHistorySnapshot where repo_id == repo_id order by week_start asc
		} or { return ctx.db_error(err) }
		rows := db_exec_param_values(mut app.db,
			'select l.id, l.snapshot_id, l.name, l.code from ${sql_table('LocHistoryLanguage')} l join ${sql_table('LocHistorySnapshot')} s on s.id = l.snapshot_id where s.repo_id = ${db_parameter_marker(0)} order by s.week_start, l.name',
			[repo_id.str()]) or { return ctx.db_error(err) }
		for row in rows {
			if row.len == 4 {
				name := if row[2] == 'C Header' { 'C' } else { row[2] }
				if name !in colors {
					colors[name] = highlight.language_color(name) or { '' }
				}
				languages << LocHistoryLanguage{
					id:          row[0].int()
					snapshot_id: row[1].int()
					name:        row[2]
					code:        row[3].int()
				}
			}
		}
	}
	return ctx.json(LocHistoryResponse{
		job:       job
		snapshots: snapshots
		languages: languages
		colors:    colors
	})
}
