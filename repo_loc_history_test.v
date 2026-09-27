module main

import config
import git
import os

fn loc_test_app() !(&App, string) {
	db_path := os.join_path(os.temp_dir(), 'gitly_loc_test_${os.getpid()}.sqlite')
	os.rm(db_path) or {}
	conf := config.Config{
		repo_storage_path: os.temp_dir()
		archive_path:      os.temp_dir()
		avatars_path:      os.temp_dir()
		sqlite:            config.SqliteConfig{
			path: db_path
		}
	}
	mut app := &App{
		db:     connect_db(conf)!
		config: conf
	}
	app.create_tables()!
	return app, db_path
}

fn loc_test_git(dir string, args []string) string {
	result := git.Git.exec_in_dir(dir, args)
	if result.exit_code != 0 {
		panic('git ${args} failed: ${result.output}')
	}
	return result.output.trim_space()
}

fn loc_test_commit(dir string, file_name string, content string, date string) ! {
	os.write_file(os.join_path(dir, file_name), content)!
	loc_test_git(dir, ['add', file_name])
	result := git.Git.exec_in_dir_with_env(dir, ['commit', '-m', file_name], {
		'GIT_AUTHOR_DATE':    date
		'GIT_COMMITTER_DATE': date
	})
	if result.exit_code != 0 {
		return error('git commit failed: ${result.output}')
	}
}

fn test_weekly_loc_revisions_selects_last_commit_in_each_week() {
	base := loc_week_start(1_767_225_600) // 2026-01-01
	log := '${base + 10}\t${'a'.repeat(40)}\n${base + 60}\t${'b'.repeat(40)}\n${base + loc_week_seconds + 40}\t${'c'.repeat(40)}\n'
	weeks := weekly_loc_revisions(log, base + loc_week_seconds + 40)!
	assert weeks.len == 2
	assert weeks[0].week_start == base
	assert weeks[0].oid == 'b'.repeat(40)
	assert weeks[1].week_start == base + loc_week_seconds
	assert weeks[1].oid == 'c'.repeat(40)
	backdated := weekly_loc_revisions('${base + 10}\t${'a'.repeat(40)}\n${base + 5}\t${'b'.repeat(40)}\n',
		base + 10)!
	assert backdated.len == 1
	assert backdated[0].oid == 'b'.repeat(40)
}

fn test_loc_history_counts_and_caches_weekly_languages() {
	$if sqlite ? {
		if _ := os.find_abs_path_of_executable('scc') {
			mut app, db_path := loc_test_app()!
			repo_dir := os.join_path(os.temp_dir(), 'gitly_repo_loc_history_${os.getpid()}')
			os.rmdir_all(repo_dir) or {}
			os.mkdir_all(repo_dir)!
			loc_test_git(repo_dir, ['init', '-b', 'main'])
			loc_test_git(repo_dir, ['config', 'user.name', 'LOC Test'])
			loc_test_git(repo_dir, ['config', 'user.email', 'loc-test@example.com'])
			defer {
				app.db.close() or {}
				os.rmdir_all(repo_dir) or {}
				for suffix in ['', '-shm', '-wal'] {
					os.rm(db_path + suffix) or {}
				}
			}
			app.db.exec('create unique index idx_loc_history_job_repo_test on ${sql_table('LocHistoryJob')} (repo_id)')!
			app.db.exec('create unique index idx_loc_history_snapshot_week_test on ${sql_table('LocHistorySnapshot')} (repo_id, week_start)')!
			loc_test_commit(repo_dir, 'main.py', 'print("hello")\n', '2026-01-01T12:00:00Z')!
			loc_test_commit(repo_dir, 'main.v', 'fn main() {\n println("hi")\n}\n', '2026-01-08T12:00:00Z')!
			repo := Repo{
				id:             1
				name:           'loc-history'
				user_id:        1
				user_name:      'owner'
				git_dir:        repo_dir
				primary_branch: 'main'
			}
			app.add_repo(repo)!
			assert app.queue_loc_history(repo.id)!
			assert !app.queue_loc_history(repo.id)!
			app.calculate_loc_history(repo.id)!
			job := app.find_loc_history_job(repo.id)
			assert job.status == 'done'
			assert job.total >= 2
			assert job.completed == job.total
			repo_id := repo.id
			snapshots := sql app.db {
				select from LocHistorySnapshot where repo_id == repo_id order by week_start asc
			}!
			assert snapshots.len == job.total
			assert snapshots[0].total_code == 1
			assert snapshots[1].total_code > snapshots[0].total_code
			second_id := snapshots[1].id
			languages := sql app.db {
				select from LocHistoryLanguage where snapshot_id == second_id
			}!
			assert languages.any(it.name == 'Python' && it.code == 1)
			assert languages.any(it.name == 'V' && it.code > 0)
			assert app.queue_loc_history(repo.id)!
			assert app.find_loc_history_job(repo.id).status == 'queued'
		} else {
			// The integration measurement runs on hosts with scc installed.
			assert true
		}
	} $else {
		assert true
	}
}
