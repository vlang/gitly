module main

import config
import git
import net.http
import os
import rand
import veb

fn ai_authorization_git(args []string) string {
	result := git.Git.exec(args)
	if result.exit_code != 0 {
		panic('git ${args} failed: ${result.output}')
	}
	return result.output.trim_space()
}

fn ai_authorization_fixture(is_public bool) !(&App, string, Repo, PullRequest, string) {
	root := os.join_path(os.temp_dir(), 'gitly_ai_authorization_${rand.ulid()}')
	os.mkdir_all(root)!
	work := os.join_path(root, 'work')
	bare := os.join_path(root, 'project.git')
	ai_authorization_git(['init', '-b', 'main', work])
	ai_authorization_git(['-C', work, 'config', 'user.name', 'AI Test'])
	ai_authorization_git(['-C', work, 'config', 'user.email', 'ai-test@example.test'])
	os.write_file(os.join_path(work, 'README.md'), 'test repository\n')!
	ai_authorization_git(['-C', work, 'add', 'README.md'])
	ai_authorization_git(['-C', work, 'commit', '-m', 'Initial source'])
	ai_authorization_git(['-C', work, 'branch', 'feature'])
	ai_authorization_git(['clone', '--bare', work, bare])
	head_oid := ai_authorization_git(['-C', bare, 'rev-parse', 'refs/heads/feature'])
	conf := config.Config{
		repo_storage_path: root
		archive_path:      root
		avatars_path:      root
		ci_service_url:    'http://127.0.0.1:1'
		ci_secret:         'test-ci-secret'
		sqlite:            config.SqliteConfig{
			path: os.join_path(root, 'test.sqlite')
		}
	}
	mut app := &App{
		db:     connect_db(conf)!
		config: conf
	}
	app.create_tables()!
	for user in [User{ id: 1, username: 'owner', is_registered: true },
		User{ id: 2, username: 'developer', is_registered: true },
		User{ id: 3, username: 'reader', is_registered: true }] {
		sql app.db {
			insert user into User
		}!
	}
	app.add_repo(Repo{
		id:             1
		git_dir:        bare
		name:           'project'
		user_id:        1
		user_name:      'owner'
		is_public:      is_public
		primary_branch: 'main'
		status:         .done
	})!
	repo := app.find_repo_by_id(1) or { panic('test repository missing') }
	pr_id := app.add_pull_request(repo.id, 1, 'Fix feature', '', 'feature', 'main')!
	pr := app.find_pull_request_by_id(pr_id) or { panic('test PR missing') }
	app.add_ci_status(CiStatus{
		repo_id:     repo.id
		commit_hash: head_oid
		branch:      'feature'
		status:      .failure
		ci_run_id:   101
	})!
	return app, root, repo, pr, head_oid
}

fn ai_authorization_cleanup(mut app App, root string) {
	app.db.close() or {}
	os.rmdir_all(root) or {}
}

fn test_ai_fix_requires_latest_failed_attempt_for_actual_full_head() {
	$if sqlite ? {
		mut app, root, repo, pr, head_oid := ai_authorization_fixture(true)!
		defer { ai_authorization_cleanup(mut app, root) }
		initial := app.ai_fix_context(1, repo, pr)!
		assert initial.head_oid == head_oid
		assert initial.source_repo.id == repo.id
		assert initial.ci_status.ci_run_id == 101
		assert app.can_ai_fix_pull_request(1, repo, pr)

		// A newer retry supersedes an older failure even for the same commit.
		app.upsert_ci_status(repo.id, head_oid, 'feature', .pending, 102)!
		assert !app.can_ai_fix_pull_request(1, repo, pr)
		assert (app.pull_request_ci_status(1, repo, pr) or { panic('CI missing') }).status == .pending
		assert app.apply_ci_status_callback(repo.id, head_oid, 'feature', 102, .success)!
		assert !app.can_ai_fix_pull_request(1, repo, pr)
		app.upsert_ci_status(repo.id, head_oid, 'feature', .timed_out, 103)!
		assert app.can_ai_fix_pull_request(1, repo, pr)
		app.upsert_ci_status(repo.id, head_oid, 'feature', .cancelled, 104)!
		assert !app.can_ai_fix_pull_request(1, repo, pr)

		// Neither another branch nor a previous commit supplies current CI.
		app.upsert_ci_status(repo.id, head_oid, 'unrelated', .failure, 105)!
		assert !app.can_ai_fix_pull_request(1, repo, pr)
		app.upsert_ci_status(repo.id, head_oid, 'feature', .failure, 106)!
		assert app.can_ai_fix_pull_request(1, repo, pr)
		tree := ai_authorization_git(['-C', repo.git_dir, 'rev-parse', '${head_oid}^{tree}'])
		new_head := git_commit_tree(repo.git_dir, tree, [head_oid], 'Test User', 'New source revision')!
		update_git_ref_expected(repo.git_dir, 'refs/heads/feature', new_head, head_oid)!
		assert !app.can_ai_fix_pull_request(1, repo, pr)
		assert app.pull_request_ci_status(1, repo, pr) == none
		app.upsert_ci_status(repo.id, new_head, 'feature', .failure, 107)!
		assert (app.ai_fix_context(1, repo, pr)!).head_oid == new_head

		// A failed trigger has no runner logs, and ambiguous run IDs fail closed.
		app.add_ci_status(CiStatus{
			repo_id:     repo.id
			commit_hash: new_head
			branch:      'feature'
			status:      .failure
			ci_run_id:   0
		})!
		assert !app.can_ai_fix_pull_request(1, repo, pr)
		app.upsert_ci_status(repo.id, new_head, 'feature', .failure, 108)!
		assert app.can_ai_fix_pull_request(1, repo, pr)
		app.add_ci_status(CiStatus{
			repo_id:     999
			commit_hash: new_head
			branch:      'feature'
			status:      .failure
			ci_run_id:   108
		})!
		assert !app.can_ai_fix_pull_request(1, repo, pr)
	} $else {
		assert true
	}
}

fn test_ai_fix_respects_push_protection_signed_commits_and_open_pr_state() {
	$if sqlite ? {
		mut app, root, repo, pr, _ := ai_authorization_fixture(true)!
		defer { ai_authorization_cleanup(mut app, root) }
		assert !app.can_ai_fix_pull_request(0, repo, pr)
		assert !app.can_ai_fix_pull_request(3, repo, pr)
		assert app.pull_request_ci_status(3, repo, pr) != none
		app.add_project_member(repo.id, 2, 'developer')!
		assert app.can_ai_fix_pull_request(2, repo, pr)
		rule := app.protect_branch(repo.id, 'feature', project_access_maintainer, project_access_maintainer)!
		assert !app.can_ai_fix_pull_request(2, repo, pr)
		assert app.can_ai_fix_pull_request(1, repo, pr)
		app.update_protected_branch(repo.id, rule, project_access_no_one, project_access_maintainer)!
		assert !app.can_ai_fix_pull_request(1, repo, pr)
		app.unprotect_branch(repo.id, rule)!
		assert app.can_ai_fix_pull_request(1, repo, pr)

		for state in [PrStatus.closed, PrStatus.merged] {
			assert !app.can_ai_fix_pull_request(1, repo, PullRequest{ ...pr, status: int(state) })
		}
		assert !app.can_ai_fix_pull_request(1, repo, PullRequest{ ...pr, repo_id: 999 })
		assert !app.can_ai_fix_pull_request(1, repo, PullRequest{ ...pr, head_branch: 'missing' })
		assert !app.can_ai_fix_pull_request(1, repo, PullRequest{ ...pr, head_branch: '../main' })

		repo_id := repo.id
		required := true
		sql app.db {
			update Repo set require_signed_commits = required where id == repo_id
		}!
		signed_repo := app.find_repo_by_id(repo.id) or { panic('repository missing') }
		assert !app.can_ai_fix_pull_request(1, signed_repo, pr)
		assert app.pull_request_ci_status(1, signed_repo, pr) != none

		unsigned := false
		sql app.db {
			update Repo set require_signed_commits = unsigned where id == repo_id
		}!
		assert app.can_ai_fix_pull_request(1, repo, pr)
		configured := app.config
		app.config = config.Config{ ...configured, ci_service_url: '' }
		assert !app.can_ai_fix_pull_request(1, repo, pr)
		app.config = config.Config{ ...configured, ci_secret: '' }
		assert !app.can_ai_fix_pull_request(1, repo, pr)
	} $else {
		assert true
	}
}

fn test_ai_fix_revoked_private_member_loses_action_and_ci_visibility() {
	$if sqlite ? {
		mut app, root, repo, pr, _ := ai_authorization_fixture(false)!
		defer { ai_authorization_cleanup(mut app, root) }
		member := app.add_project_member(repo.id, 2, 'developer')!
		assert app.can_ai_fix_pull_request(2, repo, pr)
		assert app.pull_request_ci_status(2, repo, pr) != none
		app.remove_project_member(repo.id, member)!
		assert !app.can_ai_fix_pull_request(2, repo, pr)
		assert app.pull_request_ci_status(2, repo, pr) == none
		assert app.pull_request_ci_status(0, repo, pr) == none
	} $else {
		assert true
	}
}

fn test_ai_fix_cross_fork_checks_source_permissions_and_source_ci_identity() {
	$if sqlite ? {
		mut app, root, target, _, head_oid := ai_authorization_fixture(true)!
		defer { ai_authorization_cleanup(mut app, root) }
		fork_dir := os.join_path(root, 'fork.git')
		ai_authorization_git(['clone', '--bare', target.git_dir, fork_dir])
		app.add_repo(Repo{
			id:             2
			git_dir:        fork_dir
			name:           'fork'
			user_id:        2
			user_name:      'developer'
			primary_branch: 'main'
			status:         .done
		})!
		relation := RepoFork{ repo_id: 2, source_repo_id: target.id, root_repo_id: target.id, created_by: 2 }
		sql app.db {
			insert relation into RepoFork
		}!
		pr_id := app.add_pull_request_from_repo(target.id, 2, 2, 'Fork feature', '', 'feature', 'main')!
		pr := app.find_pull_request_by_id(pr_id) or { panic('fork PR missing') }
		// The target has a failure at this OID, but the source fork has no CI yet.
		assert !app.can_ai_fix_pull_request(2, target, pr)
		assert app.pull_request_ci_status(2, target, pr) == none
		app.upsert_ci_status(2, head_oid, 'feature', .failure, 201)!
		context := app.ai_fix_context(2, target, pr)!
		assert context.source_repo.id == 2
		assert context.ci_status.repo_id == 2
		assert context.ci_status.ci_run_id == 201
		assert context.head_oid == head_oid
		// No cached target PR ref is needed to identify the actual source tip.
		assert git.Git.exec_in_dir(target.git_dir, ['show-ref', '--verify', pr.head_ref()]).exit_code != 0

		// Owning the target confers no access to this private source fork.
		assert !app.can_ai_fix_pull_request(1, target, pr)
		assert app.pull_request_ci_status(1, target, pr) == none
		member := app.add_project_member(2, 1, 'reporter')!
		assert app.pull_request_ci_status(1, target, pr) != none
		assert !app.can_ai_fix_pull_request(1, target, pr)
		app.update_project_member_role(2, member, 'developer')!
		assert app.can_ai_fix_pull_request(1, target, pr)
		app.remove_project_member(2, member)!
		assert !app.can_ai_fix_pull_request(1, target, pr)

		// A branch move in the fork cannot reuse the target or old source status.
		tree := ai_authorization_git(['-C', fork_dir, 'rev-parse', '${head_oid}^{tree}'])
		new_head := git_commit_tree(fork_dir, tree, [head_oid], 'Fork User', 'New fork revision')!
		update_git_ref_expected(fork_dir, 'refs/heads/feature', new_head, head_oid)!
		assert app.pull_request_ci_status(2, target, pr) == none
		assert !app.can_ai_fix_pull_request(2, target, pr)
		app.upsert_ci_status(2, new_head, 'feature', .failure, 202)!
		assert (app.ai_fix_context(2, target, pr)!).head_oid == new_head

		fork_id := 2
		sql app.db {
			delete from RepoFork where repo_id == fork_id
		}!
		assert !app.can_ai_fix_pull_request(2, target, pr)
		assert app.pull_request_ci_status(2, target, pr) == none
	} $else {
		assert true
	}
}

fn test_ai_fix_ci_details_require_exact_registered_failed_run() {
	ci := CiStatus{
		id:          1
		repo_id:     1
		commit_hash: '0123456789abcdef0123456789abcdef01234567'
		branch:      'feature'
		status:      .failure
		ci_run_id:   123
	}
	run := CiRunDetail{
		id:          ci.ci_run_id
		commit_hash: ci.commit_hash
		branch:      ci.branch
		status:      'failure'
	}
	assert ai_fix_ci_run_matches(ci, run)
	assert !ai_fix_ci_run_matches(ci, CiRunDetail{ ...run, id: 124 })
	assert !ai_fix_ci_run_matches(ci, CiRunDetail{ ...run, branch: 'main' })
	assert !ai_fix_ci_run_matches(ci, CiRunDetail{ ...run, commit_hash: 'abcdef0123456789abcdef0123456789abcdef01' })
	assert !ai_fix_ci_run_matches(ci, CiRunDetail{ ...run, commit_hash: ci.commit_hash[..8] })
	for status in ['pending', 'running', 'success', 'cancelled', 'timed_out', 'unknown'] {
		assert !ai_fix_ci_run_matches(ci, CiRunDetail{ ...run, status: status })
	}
	assert ai_fix_ci_run_matches(CiStatus{ ...ci, status: .timed_out }, CiRunDetail{ ...run, status: 'timed_out' })
	assert !ai_fix_ci_run_matches(CiStatus{ ...ci, status: .success }, run)
	assert !ai_fix_ci_run_matches(CiStatus{ ...ci, ci_run_id: 0 }, CiRunDetail{ ...run, id: 0 })
}

fn test_ai_fix_csrf_tokens_are_bound_to_session_repository_and_pr() {
	token := ai_fix_csrf_token('server-secret', 'session-one', 1, 2)
	assert token != ''
	assert token == ai_fix_csrf_token('server-secret', 'session-one', 1, 2)
	assert token != ai_fix_csrf_token('other-secret', 'session-one', 1, 2)
	assert token != ai_fix_csrf_token('server-secret', 'session-two', 1, 2)
	assert token != ai_fix_csrf_token('server-secret', 'session-one', 2, 2)
	assert token != ai_fix_csrf_token('server-secret', 'session-one', 1, 3)
	assert ai_fix_csrf_token('', 'session-one', 1, 2) == ''
	assert ai_fix_csrf_token('server-secret', '', 1, 2) == ''
	assert ai_fix_csrf_token('server-secret', 'session-one', 0, 2) == ''
	assert ai_fix_csrf_token('server-secret', 'session-one', 1, 0) == ''
}

fn ai_authorization_request(user User, session_token string, form map[string]string) Context {
	mut req := http.Request{
		method: .post
		url:    '/owner/project/pull/1/ai-fix'
		header: http.new_header()
	}
	if session_token != '' {
		req.header.set(.cookie, 'token=${session_token}')
		// Direct handler calls bypass HTTP parsing, which normally fills this map.
		req.add_cookie(http.Cookie{ name: 'token', value: session_token })
	}
	return Context{
		Context:   veb.Context{
			req:  req
			form: form.clone()
			res:  http.Response{
				header: http.new_header()
			}
		}
		logged_in: true
		user:      user
	}
}

fn ai_authorization_post(mut app App, mut ctx Context, repo Repo, pr PullRequest, apply bool) {
	if apply {
		app.apply_pull_request_ai_fix(mut ctx, repo.user_name, repo.name, pr.id.str())
	} else {
		app.generate_pull_request_ai_fix(mut ctx, repo.user_name, repo.name, pr.id.str())
	}
}

fn test_ai_fix_posts_reject_csrf_stale_identity_and_invalid_patch_before_side_effects() {
	$if sqlite ? {
		mut app, root, repo, pr, head_oid := ai_authorization_fixture(true)!
		defer { ai_authorization_cleanup(mut app, root) }
		user := app.get_user_by_id(1) or { panic('owner missing') }
		session_token := 'test-browser-session'
		csrf := ai_fix_csrf_token(app.config.ci_secret, session_token, repo.id, pr.id)
		base_form := {
			'csrf_token':   csrf
			'head_oid':     head_oid
			'ci_run_id':    '101'
			'provider':     'claude'
			'api_key':      'request-secret-must-not-be-rendered'
			'patch_base64': 'invalid!encoding'
		}
		for apply in [false, true] {
			for submitted_token in ['', 'wrong-csrf-token'] {
				mut form := base_form.clone()
				form['csrf_token'] = submitted_token
				mut ctx := ai_authorization_request(user, session_token, form)
				ai_authorization_post(mut app, mut ctx, repo, pr, apply)
				assert ctx.res.status_code == 403
				assert !ctx.res.body.contains(base_form['api_key'])
				assert ctx.res.header.get(.cache_control) or { '' } == 'no-store'
			}
			mut missing_cookie := ai_authorization_request(user, '', base_form)
			ai_authorization_post(mut app, mut missing_cookie, repo, pr, apply)
			assert missing_cookie.res.status_code == 403

			mut stale_form := base_form.clone()
			stale_form['head_oid'] = '0'.repeat(head_oid.len)
			mut stale := ai_authorization_request(user, session_token, stale_form)
			ai_authorization_post(mut app, mut stale, repo, pr, apply)
			assert stale.res.status_code == 409
			assert stale.res.body.contains('changed')
			assert !stale.res.body.contains(base_form['api_key'])
		}

		mut malformed_patch := ai_authorization_request(user, session_token, base_form)
		app.apply_pull_request_ai_fix(mut malformed_patch, repo.user_name, repo.name, pr.id.str())
		assert malformed_patch.res.status_code == 400
		assert malformed_patch.res.body.contains('encoding')
		assert ai_authorization_git(['-C', repo.git_dir, 'rev-parse', 'refs/heads/feature']) == head_oid

		// A newer failed attempt must invalidate a form for the old run too.
		app.upsert_ci_status(repo.id, head_oid, 'feature', .failure, 102)!
		for apply in [false, true] {
			mut stale_run := ai_authorization_request(user, session_token, base_form)
			ai_authorization_post(mut app, mut stale_run, repo, pr, apply)
			assert stale_run.res.status_code == 409
			assert stale_run.res.body.contains('changed')
		}
		assert ai_authorization_git(['-C', repo.git_dir, 'rev-parse', 'refs/heads/feature']) == head_oid
		assert (app.find_ci_status_for_commit(repo.id, head_oid, 'feature') or {
			panic('CI missing')
		}).ci_run_id == 102
	} $else {
		assert true
	}
}

fn test_ai_fix_direct_posts_reject_revoked_push_permission() {
	$if sqlite ? {
		mut app, root, repo, pr, head_oid := ai_authorization_fixture(true)!
		defer { ai_authorization_cleanup(mut app, root) }
		member := app.add_project_member(repo.id, 2, 'developer')!
		assert app.can_ai_fix_pull_request(2, repo, pr)
		user := app.get_user_by_id(2) or { panic('developer missing') }
		session_token := 'developer-browser-session'
		form := {
			'csrf_token':   ai_fix_csrf_token(app.config.ci_secret, session_token, repo.id, pr.id)
			'head_oid':     head_oid
			'ci_run_id':    '101'
			'provider':     'claude'
			'api_key':      'request-secret'
			'patch_base64': 'invalid!encoding'
		}
		app.remove_project_member(repo.id, member)!
		for apply in [false, true] {
			mut ctx := ai_authorization_request(user, session_token, form)
			ai_authorization_post(mut app, mut ctx, repo, pr, apply)
			assert ctx.res.status_code == 409
			assert ctx.res.body.contains('not allowed to push')
			assert !ctx.res.body.contains(form['api_key'])
		}
		assert ai_authorization_git(['-C', repo.git_dir, 'rev-parse', 'refs/heads/feature']) == head_oid
	} $else {
		assert true
	}
}
