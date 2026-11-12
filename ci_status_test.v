module main

import config
import git
import os

fn ci_status_test_app() !(&App, string) {
	db_path := os.join_path(os.temp_dir(), 'gitly_ci_status_${os.getpid()}.sqlite')
	for suffix in ['', '-shm', '-wal'] {
		os.rm(db_path + suffix) or {}
	}
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

fn cleanup_ci_status_test(mut app App, db_path string) {
	app.db.close() or {}
	for suffix in ['', '-shm', '-wal'] {
		os.rm(db_path + suffix) or {}
	}
}

fn ci_trigger_response_is_error(status_code int, body string) bool {
	ci_run_id_from_trigger_response(status_code, body) or { return true }
	return false
}

fn ci_callback_url_is_error(conf config.Config) bool {
	ci_callback_url_for_config(conf) or { return true }
	return false
}

fn ci_bind_is_error(mut app App, repo_id int, commit_hash string, branch string, reservation int, ci_run_id int) bool {
	app.bind_ci_status_run(repo_id, commit_hash, branch, reservation, ci_run_id) or { return true }
	return false
}

fn ci_begin_is_error(mut app App, repo_id int, commit_hash string, branch string) bool {
	app.begin_ci_status(repo_id, commit_hash, branch) or { return true }
	return false
}

fn ci_upsert_is_error(mut app App, repo_id int, commit_hash string, branch string, ci_run_id int) bool {
	app.upsert_ci_status(repo_id, commit_hash, branch, .pending, ci_run_id) or { return true }
	return false
}

fn test_ci_trigger_response_requires_successful_valid_run() {
	assert is_full_commit_oid('0123456789abcdef0123456789abcdef01234567')
	assert is_full_commit_oid('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef')
	assert !is_full_commit_oid('01234567')
	assert !is_full_commit_oid('0123456789ABCDEF0123456789abcdef01234567')
	assert ci_run_id_from_trigger_response(201,
		'{"success":true,"result":{"id":42,"status":"pending"}}')! == 42
	assert ci_trigger_response_is_error(503,
		'{"success":true,"result":{"id":42,"status":"pending"}}')
	assert ci_trigger_response_is_error(200, 'not json')
	assert ci_trigger_response_is_error(200,
		'{"success":false,"result":{"id":42,"status":"pending"}}')
	assert ci_trigger_response_is_error(200,
		'{"success":true,"result":{"id":0,"status":"pending"}}')
}

fn test_ci_callback_url_can_be_configured_or_derived() {
	assert ci_callback_url_for_config(config.Config{
		hostname: 'gitly.test'
	})! == 'http://gitly.test/api/v1/ci/status'
	assert ci_callback_url_for_config(config.Config{
		hostname:      'gitly.test'
		cookie_secure: true
	})! == 'https://gitly.test/api/v1/ci/status'
	assert ci_callback_url_for_config(config.Config{
		hostname:        'ignored.test'
		ci_callback_url: 'https://public.test/hooks/gitly-ci'
	})! == 'https://public.test/hooks/gitly-ci'
	assert ci_callback_url_is_error(config.Config{
		hostname:        'gitly.test'
		ci_callback_url: 'file:///tmp/status'
	})
	assert ci_callback_url_is_error(config.Config{
		hostname:        'gitly.test'
		ci_callback_url: 'https://public.test/hooks?token=secret'
	})
}

fn test_ci_callbacks_update_only_their_registered_run() {
	$if sqlite ? {
		mut app, db_path := ci_status_test_app()!
		defer {
			cleanup_ci_status_test(mut app, db_path)
		}
		commit_hash := '0123456789abcdef0123456789abcdef01234567'
		first := app.begin_ci_status(1, commit_hash, 'main')!
		second := app.begin_ci_status(1, commit_hash, 'main')!
		assert first < 0
		assert second < 0
		assert first != second
		assert app.has_ci_status_reservation(1, commit_hash, 'main')
		app.bind_ci_status_run(1, commit_hash, 'main', first, 101)!
		app.bind_ci_status_run(1, commit_hash, 'main', second, 202)!
		assert ci_bind_is_error(mut app, 1, commit_hash, 'main', second, 303)
		assert !app.has_ci_status_reservation(1, commit_hash, 'main')

		current_before := app.find_ci_status_for_commit(1, commit_hash, 'main') or {
			panic('current CI status missing')
		}
		assert current_before.ci_run_id == 202
		assert current_before.status == .pending

		assert app.apply_ci_status_callback(1, commit_hash, 'main', 101, .failure)!
		old_run := app.find_ci_status_for_run(1, 101) or { panic('old CI run missing') }
		assert old_run.status == .failure
		current_after_old_callback := app.find_ci_status_for_commit(1, commit_hash, 'main') or {
			panic('current CI status missing')
		}
		assert current_after_old_callback.ci_run_id == 202
		assert current_after_old_callback.status == .pending

		assert !app.apply_ci_status_callback(1, commit_hash, 'other', 202, .success)!
		assert !app.apply_ci_status_callback(1, commit_hash, 'main', 999, .success)!
		assert app.apply_ci_status_callback(1, commit_hash, 'main', 202, .success)!
		current_after_current_callback := app.find_ci_status_for_commit(1, commit_hash, 'main') or {
			panic('current CI status missing')
		}
		assert current_after_current_callback.ci_run_id == 202
		assert current_after_current_callback.status == .success
		assert app.apply_ci_status_callback(1, commit_hash, 'main', 202, .running)!
		assert app.apply_ci_status_callback(1, commit_hash, 'main', 202, .failure)!
		terminal_run := app.find_ci_status_for_run(1, 202) or { panic('terminal CI run missing') }
		assert terminal_run.status == .success

		third := app.begin_ci_status(1, commit_hash, 'main')!
		app.bind_ci_status_run(1, commit_hash, 'main', third, 303)!
		assert app.apply_ci_status_callback(1, commit_hash, 'main', 303, .running)!
		assert app.apply_ci_status_callback(1, commit_hash, 'main', 303, .pending)!
		running_run := app.find_ci_status_for_run(1, 303) or { panic('running CI run missing') }
		assert running_run.status == .running
		assert app.apply_ci_status_callback(1, commit_hash, 'main', 303, .failure)!
		assert app.apply_ci_status_callback(1, commit_hash, 'main', 303, .success)!
		failed_run := app.find_ci_status_for_run(1, 303) or { panic('failed CI run missing') }
		assert failed_run.status == .failure
	} $else {
		assert true
	}
}

fn test_failed_trigger_finishes_only_its_reservation() {
	$if sqlite ? {
		mut app, db_path := ci_status_test_app()!
		defer {
			cleanup_ci_status_test(mut app, db_path)
		}
		commit_hash := 'abcdef0123456789abcdef0123456789abcdef01'
		older := app.begin_ci_status(1, commit_hash, 'main')!
		newer := app.begin_ci_status(1, commit_hash, 'main')!
		app.fail_ci_status_reservation(1, commit_hash, 'main', older)!

		current := app.find_ci_status_for_commit(1, commit_hash, 'main') or {
			panic('current CI status missing')
		}
		assert current.ci_run_id == newer
		assert current.status == .pending

		app.fail_ci_status_reservation(1, commit_hash, 'main', newer)!
		failed := app.find_ci_status_for_commit(1, commit_hash, 'main') or {
			panic('failed CI status missing')
		}
		assert failed.ci_run_id == 0
		assert failed.status == .failure
	} $else {
		assert true
	}
}

fn test_ci_status_identity_includes_full_oid_branch_and_attempt() {
	$if sqlite ? {
		mut app, db_path := ci_status_test_app()!
		defer {
			cleanup_ci_status_test(mut app, db_path)
		}
		commit_hash := '1234567890abcdef1234567890abcdef12345678'
		other_hash := 'abcdef1234567890abcdef1234567890abcdef12'
		app.upsert_ci_status(1, commit_hash, 'main', .pending, 401)!
		app.upsert_ci_status(1, commit_hash, 'release', .pending, 402)!

		main_status := app.find_ci_status_for_commit(1, commit_hash, 'main') or {
			panic('main CI status missing')
		}
		release := app.find_ci_status_for_commit(1, commit_hash, 'release') or {
			panic('release CI status missing')
		}
		assert main_status.ci_run_id == 401
		assert release.ci_run_id == 402
		assert app.apply_ci_status_callback(1, commit_hash, 'main', 401, .success)!
		assert app.apply_ci_status_callback(1, commit_hash, 'release', 402, .running)!

		// Re-observing an attempt cannot regress its terminal state.
		app.upsert_ci_status(1, commit_hash, 'main', .pending, 401)!
		terminal := app.find_ci_status_for_run(1, 401) or { panic('terminal run missing') }
		assert terminal.status == .success

		// A new id is a distinct attempt, even for the same branch and commit.
		app.upsert_ci_status(1, commit_hash, 'main', .pending, 403)!
		latest_main := app.find_ci_status_for_commit(1, commit_hash, 'main') or {
			panic('latest main CI status missing')
		}
		assert latest_main.ci_run_id == 403
		assert (app.find_ci_status_for_run(1, 401) or { CiStatus{} }).status == .success

		// A runner id cannot be rebound to another branch.
		assert ci_upsert_is_error(mut app, 1, commit_hash, 'release', 401)
		assert (app.find_ci_status_for_commit(1, commit_hash, 'release') or { CiStatus{} }).ci_run_id == 402

		// A known untested commit must not inherit a stale branch status.
		assert (app.find_ci_status_for_tree(1, other_hash, 'main') or { CiStatus{} }).id == 0
		assert (app.find_ci_status_for_tree(1, commit_hash[..8], 'main') or { CiStatus{} }).id == 0
		assert ci_begin_is_error(mut app, 1, commit_hash[..8], 'main')
		assert !app.apply_ci_status_callback(1, commit_hash[..8], 'main', 403, .success)!

		// Legacy abbreviated records remain visible only as an explicit branch
		// fallback, never as the status of the corresponding full object id.
		legacy := CiStatus{
			repo_id:     1
			commit_hash: commit_hash[..8]
			branch:      'legacy'
			status:      .failure
			ci_run_id:   99
		}
		sql app.db {
			insert legacy into CiStatus
		}!
		assert (app.find_ci_status_for_tree(1, commit_hash, 'legacy') or { CiStatus{} }).id == 0
		assert (app.find_ci_status_for_tree(1, '', 'legacy') or { CiStatus{} }).ci_run_id == 99
	} $else {
		assert true
	}
}

fn test_ci_restart_result_must_preserve_source_identity() {
	commit_hash := 'fedcba0987654321fedcba0987654321fedcba09'
	source := CiStatus{
		id:          1
		repo_id:     7
		commit_hash: commit_hash
		branch:      'release/1.0'
		ci_run_id:   50
	}
	valid := CiRunDetail{
		id:          51
		commit_hash: commit_hash
		branch:      'release/1.0'
	}
	assert ci_restart_result_matches(source, valid)
	assert !ci_restart_result_matches(source, CiRunDetail{
		...valid
		id: 50
	})
	assert !ci_restart_result_matches(source, CiRunDetail{
		...valid
		commit_hash: commit_hash[..8]
	})
	assert !ci_restart_result_matches(source, CiRunDetail{
		...valid
		branch: 'main'
	})
}

fn test_last_branch_commit_hash_is_full_oid() {
	repo_dir := os.join_path(os.temp_dir(), 'gitly_ci_oid_${os.getpid()}')
	os.rmdir_all(repo_dir) or {}
	defer {
		os.rmdir_all(repo_dir) or {}
	}
	init := git.Git.exec(['init', '--initial-branch=main', repo_dir])
	assert init.exit_code == 0
	assert git.Git.exec_in_dir(repo_dir, ['config', 'user.email', 'ci@example.com']).exit_code == 0
	assert git.Git.exec_in_dir(repo_dir, ['config', 'user.name', 'CI Test']).exit_code == 0
	os.write_file(os.join_path(repo_dir, 'README.md'), 'full oid\n')!
	assert git.Git.exec_in_dir(repo_dir, ['add', 'README.md']).exit_code == 0
	assert git.Git.exec_in_dir(repo_dir, ['commit', '-m', 'initial']).exit_code == 0

	repo := Repo{
		git_dir: repo_dir
	}
	actual := repo.get_last_branch_commit_hash('main')
	expected := git.Git.exec_in_dir(repo_dir, ['rev-parse', 'main']).output.trim_space()
	assert actual == expected
	assert is_full_commit_oid(actual)
}
