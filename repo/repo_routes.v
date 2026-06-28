module main

import veb
import api
import crypto.sha1
import os
import time
import highlight
import validation
import git
import config

const top_files_limit = 50

@['/:username/repos']
pub fn (mut app App) user_repos(username string) veb.Result {
	exists, user := app.check_username(username)

	if !exists {
		return ctx.not_found()
	}

	mut repos := app.find_user_public_repos(user.id)

	if user.id == ctx.user.id {
		repos = app.find_user_repos(user.id)
	}

	for mut repo in repos {
		repo.lang_stats = app.find_repo_lang_stats(repo.id)
		repo.latest_commit_at = app.find_repo_last_commit_time(repo.id)
		repo.activity_buckets = app.get_repo_activity_buckets(repo.id)
	}

	return $veb.html('templates/user/repos.html')
}

@['/:username/stars']
pub fn (mut app App) user_stars(username string) veb.Result {
	exists, user := app.check_username(username)

	if !exists {
		return ctx.not_found()
	}

	repos := app.find_user_starred_repos(ctx.user.id)

	return $veb.html('templates/user/stars.html')
}

@['/:username/:repo_name/settings']
pub fn (mut app App) repo_settings(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.redirect_to_repository(username, repo_name)
	}
	is_owner := app.can_admin_repo(ctx, repo)

	if !is_owner {
		return ctx.redirect_to_repository(username, repo_name)
	}

	return $veb.html('templates/repo/settings.html')
}

@['/:username/:repo_name/settings'; post]
pub fn (mut app App) handle_update_repo_settings(username string, repo_name string, webhook_secret string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.redirect_to_repository(username, repo_name)
	}
	is_owner := app.can_admin_repo(ctx, repo)

	if !is_owner {
		return ctx.redirect_to_repository(username, repo_name)
	}

	if webhook_secret != '' && webhook_secret != repo.webhook_secret {
		webhook := sha1.hexhash(webhook_secret)
		app.set_repo_webhook_secret(repo.id, webhook) or { app.info(err.str()) }
	}

	return ctx.redirect_to_repository(username, repo_name)
}

@['/:username/:repo_name/settings/features'; post]
pub fn (mut app App) handle_update_repo_features(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.redirect_to_repository(username, repo_name)
	}
	is_owner := app.can_admin_repo(ctx, repo)

	if !is_owner {
		return ctx.redirect_to_repository(username, repo_name)
	}

	disable_discussions := 'discussions_enabled' !in ctx.form
	disable_projects := 'projects_enabled' !in ctx.form
	disable_milestones := 'milestones_enabled' !in ctx.form
	disable_wiki := 'wiki_enabled' !in ctx.form

	app.update_repo_features(repo.id, disable_discussions, disable_projects, disable_milestones,
		disable_wiki) or { app.info(err.str()) }

	return ctx.redirect('/${username}/${repo_name}/settings')
}

@['/:user/:repo_name/delete'; post]
pub fn (mut app App) handle_repo_delete(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.redirect_to_repository(username, repo_name)
	}
	is_owner := app.can_admin_repo(ctx, repo)

	if !is_owner {
		return ctx.redirect_to_repository(username, repo_name)
	}

	if ctx.form['verify'] == '${username}/${repo_name}' {
		spawn app.delete_repository(repo.id, repo.git_dir, repo.name)
	} else {
		ctx.error('Verification failed')
		return app.repo_settings(mut ctx, username, repo_name)
	}

	return ctx.redirect_to_index()
}

@['/:username/:repo_name/move'; post]
pub fn (mut app App) handle_repo_move(username string, repo_name string, dest string, verify string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.redirect_to_index()
	}
	is_owner := app.can_admin_repo(ctx, repo)

	if !is_owner {
		return ctx.redirect_to_repository(username, repo_name)
	}

	if dest != '' && verify == '${username}/${repo_name}' {
		dest_user := app.get_user_by_username(dest) or {
			ctx.error('Unknown user ${dest}')
			return app.repo_settings(mut ctx, username, repo_name)
		}

		if app.user_has_repo(dest_user.id, repo.name) {
			ctx.error('User already owns repo ${repo.name}')
			return app.repo_settings(mut ctx, username, repo_name)
		}

		if app.get_count_user_repos(dest_user.id) >= max_user_repos {
			ctx.error('User already reached the repo limit')
			return app.repo_settings(mut ctx, username, repo_name)
		}

		app.move_repo_to_user(repo.id, dest_user.id, dest_user.username) or {
			ctx.error('There was an error while moving the repo')
			return app.repo_settings(mut ctx, username, repo_name)
		}

		return ctx.redirect('/${dest_user.username}/${repo.name}')
	} else {
		ctx.error('Verification failed')

		return app.repo_settings(mut ctx, username, repo_name)
	}

	return ctx.redirect_to_index()
}

@['/:username/:repo_name']
pub fn (mut app App) handle_tree(mut ctx Context, username string, repo_name string) veb.Result {
	match repo_name {
		'repos' {
			return app.user_repos(mut ctx, username)
		}
		'issues' {
			return app.handle_get_user_issues(mut ctx, username)
		}
		'pulls' {
			return app.handle_get_user_pulls(mut ctx, username)
		}
		'settings' {
			return app.user_settings(mut ctx, username)
		}
		else {}
	}

	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	return app.tree(mut ctx, username, repo_name, repo.primary_branch, '')
}

@['/:username/:repo_name/tree/:branch_name']
pub fn (mut app App) handle_branch_tree(mut ctx Context, username string, repo_name string, branch_name string) veb.Result {
	app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	return app.tree(mut ctx, username, repo_name, branch_name, '')
}

@['/:username/:repo_name/update']
pub fn (mut app App) handle_repo_update(mut ctx Context, username string, repo_name string) veb.Result {
	mut repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.not_found()
	}

	if ctx.user.is_admin {
		app.update_repo_from_remote(mut repo) or { app.info(err.str()) }
		app.slow_fetch_files_info(mut repo, 'master', '.') or { app.info(err.str()) }
	}

	return ctx.redirect_to_repository(username, repo_name)
}

@['/new']
pub fn (mut app App) new() veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	orgs := app.find_orgs_for_user(ctx.user.id)
	selected_owner := ctx.query['owner'] or { ctx.user.username }
	return $veb.html()
}

@['/new'; post]
pub fn (mut app App) handle_new_repo(mut ctx Context, name string, clone_url string, description string, no_redirect string) veb.Result {
	println('NEW POST')
	mut valid_clone_url := clone_url
	is_clone_url_empty := validation.is_string_empty(clone_url)
	is_public := ctx.form['repo_visibility'] == 'public'
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	owner := ctx.form['owner'] or { ctx.user.username }
	mut owner_name := ctx.user.username
	mut owner_org_id := 0
	if owner != ctx.user.username {
		org := app.get_org_by_name(owner) or {
			ctx.error('Unknown owner "${owner}"')
			return app.new(mut ctx)
		}
		if !app.is_org_member(org.id, ctx.user.id) {
			ctx.error('You are not a member of "${owner}"')
			return app.new(mut ctx)
		}
		owner_name = org.name
		owner_org_id = org.id
	}
	if owner_org_id == 0 && !ctx.is_admin()
		&& app.get_count_user_repos(ctx.user.id) >= max_user_repos {
		ctx.error('You have reached the limit for the number of repositories')
		return app.new(mut ctx)
	}
	if name.len > max_repo_name_len {
		ctx.error('The repository name is too long (should be fewer than ${max_repo_name_len} characters)')
		return app.new(mut ctx)
	}
	eprintln(1)
	if _ := app.find_repo_by_name_and_username(name, owner_name) {
		ctx.error('A repository with the name "${name}" already exists')
		return app.new(mut ctx)
	}
	eprintln(2)
	if name.contains(' ') {
		ctx.error('Repository name cannot contain spaces')
		return app.new(mut ctx)
	}
	eprintln(3)
	is_repo_name_valid := validation.is_repository_name_valid(name)
	if !is_repo_name_valid {
		ctx.error('The repository name is not valid')
		return app.new(mut ctx)
	}
	eprintln(4)
	has_clone_url_https_prefix := clone_url.starts_with('https://')
	if !is_clone_url_empty {
		if !has_clone_url_https_prefix {
			valid_clone_url = 'https://' + clone_url
		}
		println('checking')
		is_git_repo := git.check_git_repo_url(valid_clone_url)
		println('done')
		if !is_git_repo {
			ctx.error('The repository URL does not contain any git repository or the server does not respond')
			return app.new(mut ctx)
		}
	}
	println('OK')
	owner_dir := os.join_path(app.config.repo_storage_path, owner_name)
	if !os.exists(owner_dir) {
		os.mkdir(owner_dir) or { app.info('failed to create owner dir ${owner_dir}: ${err}') }
	}
	repo_path := os.join_path(owner_dir, name)
	id := app.get_max_repo_id() + 1
	mut new_repo := &Repo{
		name:           name
		id:             id
		description:    description
		git_dir:        repo_path
		user_id:        ctx.user.id
		primary_branch: 'master'
		user_name:      owner_name
		clone_url:      valid_clone_url
		is_public:      is_public
	}
	import_issues := ctx.form['import_issues'] == '1'
	import_prs := ctx.form['import_prs'] == '1'
	eprintln('[new-repo] clone_url="${valid_clone_url}" import_issues=${import_issues} import_prs=${import_prs}')
	if is_clone_url_empty {
		os.mkdir(new_repo.git_dir) or { panic(err) }
		new_repo.git('init --bare')
	} else {
		new_repo.status = .cloning
	}
	// Insert the repo row BEFORE spawning the clone thread, so that the
	// background `set_repo_status(.done)` UPDATE has a row to match.
	app.add_repo(new_repo) or {
		ctx.error('There was an error while adding the repo ${err}')
		return app.new(mut ctx)
	}
	if !is_clone_url_empty {
		app.debug('cloning')
		clone_job_repo := *new_repo
		spawn clone_repo(clone_job_repo, app.config, import_issues, import_prs, ctx.user.id,
			!ctx.is_admin())
	}
	new_repo2 := app.find_repo_by_name_and_username(new_repo.name, owner_name) or {
		app.info('Repo was not inserted')
		return ctx.redirect('/new')
	}
	repo_id := new_repo2.id
	// $dbg;
	// primary_branch := git.get_repository_primary_branch(repo_path)
	primary_branch := new_repo2.primary_branch
	// app.debug("new_repo2: ${new_repo2}")

	app.update_repo_primary_branch(repo_id, primary_branch) or {
		ctx.error('There was an error while adding the repo')
		return app.new(mut ctx)
	}
	app.find_repo_by_id(repo_id) or { return app.new(mut ctx) }
	// Update only cloned repositories
	/*
	if !is_clone_url_empty {
		app.update_repo_from_fs(mut new_repo, true) or {
			ctx.error('There was an error while cloning the repo')
			return app.new(mut ctx)
		}
	}
	*/
	if no_redirect == '1' {
		return ctx.text('ok')
	}
	has_first_repo_activity := app.has_activity(ctx.user.id, 'first_repo')
	if !has_first_repo_activity {
		app.add_activity(ctx.user.id, 'first_repo') or { app.info(err.str()) }
	}
	return ctx.redirect('/${owner_name}/${new_repo.name}')
}

fn bg_fetch_files_info(repo_ Repo, branch string, path string, conf config.Config) {
	mut repo := repo_
	mut app := &App{
		db:     connect_db(conf) or {
			eprintln('cannot open ${db_backend_name()} db connection for bg_fetch thread: ${err}')
			return
		}
		config: conf
	}
	app.load_settings()
	app.slow_fetch_files_info(mut repo, branch, path) or {
		eprintln('bg_fetch_files_info error: ${err}')
	}
	if app.settings.tree_folder_size_enabled() {
		app.slow_fetch_folder_sizes(mut repo, branch, path) or {
			eprintln('bg_fetch_folder_sizes error: ${err}')
		}
	}
	app.db.close() or {}
}

fn clone_repo(new_repo Repo, conf config.Config, import_issues bool, import_prs bool, owner_user_id int, enforce_clone_size_limit bool) {
	mut cloned_repo := new_repo
	cloned_repo.clone(enforce_clone_size_limit)
	// Use a dedicated DB connection for the clone thread to avoid
	// sharing a connection across threads.
	mut app := &App{
		db:     connect_db(conf) or {
			eprintln('cannot open ${db_backend_name()} db connection for clone thread: ${err}')
			return
		}
		config: conf
	}
	if cloned_repo.status == .clone_failed {
		app.set_repo_status(cloned_repo.id, .clone_failed) or {
			eprintln('cannot set repo status ${err}')
		}
		app.db.close() or {}
		return
	}
	// Mark repo as done immediately so the user can browse it.
	// The tree page will fetch files from git on demand.
	app.set_repo_status(cloned_repo.id, .done) or { eprintln('cannot set repo status ${err}') }
	eprintln('clone done, repo available — indexing in background')
	// For GitHub clones, also pull the repo description and contributors list.
	// Issue and PR imports are gated on separate user opt-ins. Open PR refs are
	// fetched before indexing so the branch scanner sees pr/<number> branches.
	if cloned_repo.clone_url.contains('github.com') {
		eprintln('[clone] github imports repo_id=${cloned_repo.id} import_issues=${import_issues} import_prs=${import_prs}')
		if import_prs {
			app.import_github_pull_requests(cloned_repo, owner_user_id) or {
				eprintln('[github-pr] FAILED: ${err}')
			}
		}
		spawn bg_import_github_repo_info(cloned_repo.id, cloned_repo.clone_url,
			cloned_repo.description, conf)
		if import_issues {
			spawn bg_import_github_issues(cloned_repo.id, cloned_repo.clone_url, owner_user_id,
				conf)
		}
	}
	// Index branches, commits, and language stats in the background.
	app.update_repo_from_fs(mut cloned_repo, true) or {
		eprintln('cannot update repo from fs ${err}')
	}
	eprintln('background indexing complete')
	app.db.close() or {}
}

fn bg_import_github_repo_info(repo_id int, clone_url string, existing_description string, conf config.Config) {
	eprintln('[github-info] spawned thread for repo_id=${repo_id}')
	mut app := &App{
		db:     connect_db(conf) or {
			eprintln('[github-info] cannot open db connection: ${err}')
			return
		}
		config: conf
	}
	defer {
		app.db.close() or {}
	}
	if existing_description.trim_space() == '' {
		description := fetch_github_repo_description(clone_url)
		if description != '' {
			app.set_repo_description(repo_id, description) or {
				eprintln('[github-info] cannot save description: ${err}')
			}
		}
	}
	app.import_github_contributors(repo_id, clone_url) or {
		eprintln('[github-contrib] FAILED: ${err}')
	}
}

fn bg_import_github_issues(repo_id int, clone_url string, owner_user_id int, conf config.Config) {
	eprintln('[github-import] spawned thread for repo_id=${repo_id}')
	mut app := &App{
		db:     connect_db(conf) or {
			eprintln('[github-import] cannot open db connection for import thread: ${err}')
			return
		}
		config: conf
	}
	app.import_github_issues(repo_id, clone_url, owner_user_id) or {
		eprintln('[github-import] FAILED: ${err}')
	}
	app.db.close() or {}
}

pub fn (mut app App) kekw(mut ctx Context) veb.Result {
	clone_url := ''
	clone_progress := ''
	return $veb.html('templates/cloning_in_process.html')
}

// read_clone_progress parses a git `--progress` log file and returns
// the latest output as a single newline-separated string, ready to be
// shown inside a <pre> block. Git emits live progress with `\r` and
// stage transitions with `\n`; we collapse repeated progress lines for
// the same phase ("Counting objects", "Receiving objects", …) so only
// the most recent value for each phase remains.
fn read_clone_progress(progress_path string) string {
	raw := os.read_file(progress_path) or { return '' }
	if raw.len == 0 {
		return ''
	}
	lines := raw.replace('\r', '\n').split('\n')
	mut stages := []string{}
	mut phase_index := map[string]int{}
	for raw_line in lines {
		line := raw_line.trim_space()
		if line == '' {
			continue
		}
		if line == git.clone_size_limit_marker {
			continue
		}
		if line.starts_with('Cloning into bare repository ') {
			continue
		}
		mut body := line
		if body.starts_with('remote: ') {
			body = body[8..]
		}
		colon := body.index(':') or { -1 }
		key := if colon == -1 { body } else { body[..colon].trim_space() }
		if key in phase_index {
			stages[phase_index[key]] = line
		} else {
			phase_index[key] = stages.len
			stages << line
		}
	}
	return stages.join('\n')
}

fn clone_size_limit_failed(progress_path string) bool {
	raw := os.read_file(progress_path) or { return false }
	return raw.contains(git.clone_size_limit_marker)
}

@['/:username/:repo_name/tree/:branch_name/:path...']
pub fn (mut app App) tree(mut ctx Context, username string, repo_name string, branch_name string, path string) veb.Result {
	tree_t0 := time.ticks()
	mut tree_t := tree_t0
	mut repo := app.find_repo_by_name_and_username(repo_name, username) or {
		eprintln('tree() repo ${repo_name} not found')
		return ctx.not_found()
	}
	eprintln('[tree] find_repo: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()
	mut clone_url := ''
	mut clone_progress := ''
	if repo.status == .clone_failed {
		clone_url = repo.clone_url
		clone_progress = read_clone_progress(repo.clone_progress_path())
		if clone_size_limit_failed(repo.clone_progress_path()) {
			return $veb.html('templates/clone_size_limit.html')
		}
		return ctx.not_found()
	}
	if repo.status == .cloning {
		clone_url = repo.clone_url
		clone_progress = read_clone_progress(repo.clone_progress_path())
		return $veb.html('templates/cloning_in_process.html')
	}

	_, user := app.check_username(username)
	eprintln('[tree] check_username: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()
	if !repo.is_public {
		if user.id != ctx.user.id {
			return ctx.not_found()
		}
	}

	repo_id := repo.id

	// XTODO
	// app.fetch_tags(repo) or { app.info(err.str()) }

	ctx.current_path = path
	if path.contains('favicon.svg') {
		return ctx.not_found()
	}

	ctx.path_split = [repo_name]
	if path != '' {
		ctx.path_split << path.split('/')
	}

	ctx.is_tree = true
	ctx.branch = branch_name

	app.increment_repo_views(repo.id) or { app.info(err.str()) }
	eprintln('[tree] increment_repo_views: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()

	mut up := '/'
	can_up := path != ''
	if can_up {
		if !path.contains('/') {
			up = '../..'
		} else {
			up = ctx.req.url.all_before_last('/')
		}
	}

	tree_mode := if 'mode' in ctx.query { ctx.query['mode'] } else { 'tree' }
	is_top_files_mode := tree_mode == 'top-files'
	top_files := if is_top_files_mode {
		repo.top_files(branch_name, top_files_limit)
	} else {
		[]File{}
	}
	if is_top_files_mode {
		eprintln('[tree] top_files: ${time.ticks() - tree_t}ms')
		tree_t = time.ticks()
	}
	tree_url := if path == '' {
		'/${username}/${repo_name}/tree/${branch_name}'
	} else {
		'/${username}/${repo_name}/tree/${branch_name}/${path}'
	}
	top_files_url := '/${username}/${repo_name}/tree/${branch_name}?mode=top-files'

	mut items := app.find_repository_items(repo_id, branch_name, ctx.current_path)
	eprintln('[tree] find_repository_items (${items.len} items): ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()
	branch := app.find_repo_branch_by_name(repo.id, branch_name)
	eprintln('[tree] find_repo_branch_by_name: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()

	show_folder_size := app.settings.tree_folder_size_enabled()

	if !is_top_files_mode {
		if items.len == 0 {
			// No files in the db, fetch them from git and cache in db
			items = app.cache_repository_items(mut repo, branch_name, ctx.current_path) or {
				app.info(err.str())
				[]File{}
			}
			eprintln('[tree] cache_repository_items: ${time.ticks() - tree_t}ms')
			tree_t = time.ticks()
			// Fetch commit info in background — don't block the page
			spawn bg_fetch_files_info(repo, branch_name, ctx.current_path, app.config)
		} else if items.any(it.last_msg == '') {
			// Some files still need commit info — fetch in background
			spawn bg_fetch_files_info(repo, branch_name, ctx.current_path, app.config)
		} else if show_folder_size && items.any(it.is_dir && !it.is_size_calculated) {
			// Some folders still need size info, fetch in background
			spawn bg_fetch_files_info(repo, branch_name, ctx.current_path, app.config)
		}
	}

	// Fetch last commit message for this directory, printed at the top of the tree
	mut last_commit := Commit{}
	mut dir := File{}
	if can_up {
		mut p := path
		if p.ends_with('/') {
			p = p[0..path.len - 1]
		}
		if !p.contains('/') {
			p = '/${p}'
		}
		dir = app.find_repo_file_by_path(repo.id, branch_name, p) or { File{} }
		if dir.id != 0 {
			last_commit = app.find_repo_commit_by_hash(repo.id, dir.last_hash)
		}
	} else {
		last_commit = app.find_repo_last_commit(repo.id, branch.id)
	}
	eprintln('[tree] last_commit lookup: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()

	mut next_dir_idx := 0
	for scan_idx in 0 .. items.len {
		if items[scan_idx].is_dir {
			if scan_idx != next_dir_idx {
				moving_dir := items[scan_idx]
				mut move_idx := scan_idx
				for move_idx > next_dir_idx {
					items[move_idx] = items[move_idx - 1]
					move_idx--
				}
				items[next_dir_idx] = moving_dir
			}
			next_dir_idx++
		}
	}

	commits_count := app.get_repo_commit_count(repo.id, branch.id)
	has_commits := commits_count > 0
	eprintln('[tree] get_repo_commit_count: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()

	// Get readme after updating repository
	readme_file := find_readme_file(items) or { File{} }
	readme := render_readme(repo, branch_name, path, readme_file)
	eprintln('[tree] render_readme: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()

	license_file := find_license_file(items) or { File{} }
	mut license_file_path := ''

	if license_file.id != 0 {
		license_file_path = '/${username}/${repo_name}/blob/${branch_name}/${license_file.name}'
	}

	watcher_count := app.get_count_repo_watchers(repo_id)
	is_repo_starred := app.check_repo_starred(repo_id, ctx.user.id)
	is_repo_watcher := app.check_repo_watcher_status(repo_id, ctx.user.id)
	is_top_directory := ctx.current_path == ''
	eprintln('[tree] watcher/star/watcher_status: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()

	// CI status for last commit
	ci_status := app.find_ci_status_for_commit(repo_id, last_commit.hash) or {
		app.find_ci_status_for_branch(repo_id, branch_name) or { CiStatus{} }
	}
	has_ci := ci_status.id != 0
	eprintln('[tree] ci_status: ${time.ticks() - tree_t}ms')
	tree_t = time.ticks()

	mut sidebar_contributors := []User{}
	mut sidebar_releases := []Release{}
	if is_top_directory {
		all_contributors := app.find_repo_registered_contributor(repo_id)
		sidebar_contributors = if all_contributors.len > 12 {
			all_contributors[..12]
		} else {
			all_contributors
		}

		rels := app.find_repo_releases_as_page(repo_id, 0)
		tags := app.get_all_repo_tags(repo_id)
		for rel in rels {
			mut r := rel
			for tag in tags {
				if tag.id == rel.tag_id {
					r.tag_name = tag.name
					r.tag_hash = tag.hash
					r.date = time.unix(tag.created_at)
					break
				}
			}
			sidebar_releases << r
			if sidebar_releases.len >= 3 {
				break
			}
		}
		eprintln('[tree] sidebar contributors/releases: ${time.ticks() - tree_t}ms')
		tree_t = time.ticks()
	}

	eprintln('[tree] pre-render TOTAL ${username}/${repo_name}: ${time.ticks() - tree_t0}ms')
	return $veb.html()
}

fn render_readme(repo Repo, branch_name string, path string, readme_file File) veb.RawHtml {
	if readme_file.id == 0 {
		return veb.RawHtml('')
	}

	readme_path := '${path}/${readme_file.name}'
	readme_content := repo.read_file(branch_name, readme_path)
	highlighted_readme, _, _ := highlight.highlight_text(readme_content, readme_path, false)

	return veb.RawHtml(highlighted_readme)
}

@['/api/v1/repos/:repo_id/star'; 'post']
pub fn (mut app App) handle_api_repo_star(mut ctx Context, repo_id_str string) veb.Result {
	repo_id := repo_id_str.int()

	has_access := app.has_user_repo_read_access(ctx, ctx.user.id, repo_id)

	if !has_access {
		return ctx.json_error('Not found')
	}

	user_id := ctx.user.id
	app.toggle_repo_star(repo_id, user_id) or {
		return ctx.json_error('There was an error while starring the repo')
	}
	is_repo_starred := app.check_repo_starred(repo_id, user_id)

	return ctx.json(api.ApiSuccessResponse[bool]{
		success: true
		result:  is_repo_starred
	})
}

@['/api/v1/repos/:repo_id/watch'; 'post']
pub fn (mut app App) handle_api_repo_watch(mut ctx Context, repo_id_str string) veb.Result {
	repo_id := repo_id_str.int()

	has_access := app.has_user_repo_read_access(ctx, ctx.user.id, repo_id)

	if !has_access {
		return ctx.json_error('Not found')
	}

	user_id := ctx.user.id
	app.toggle_repo_watcher_status(repo_id, user_id) or {
		return ctx.json_error('There was an error while toggling to watch')
	}
	is_watching := app.check_repo_watcher_status(repo_id, user_id)

	return ctx.json(api.ApiSuccessResponse[bool]{
		success: true
		result:  is_watching
	})
}

// API: get file listing with commit info for a directory (used by JS polling)
// Path uses /tree/files to avoid colliding with /api/v1/repos/:username/:repo_name.
@['/api/v1/repos/:repo_id_str/tree/files']
pub fn (mut app App) handle_api_repo_files(mut ctx Context, repo_id_str string) veb.Result {
	repo_id := repo_id_str.int()
	repo := app.find_repo_by_id(repo_id) or { return ctx.json_error('Not found') }

	if !repo.is_public && repo.user_id != ctx.user.id {
		return ctx.json_error('Not found')
	}

	branch := if 'branch' in ctx.query { ctx.query['branch'] } else { '' }
	path := if 'path' in ctx.query { ctx.query['path'] } else { '' }

	if branch == '' {
		return ctx.json_error('branch is required')
	}

	items := app.find_repository_items(repo_id, branch, path)
	mut result := []FileInfo{}
	for item in items {
		result << FileInfo{
			name:      item.name
			last_msg:  item.last_msg
			last_hash: item.last_hash
			last_time: item.pretty_last_time()
			size:      item.pretty_tree_size()
		}
	}

	return ctx.json(api.ApiSuccessResponse[[]FileInfo]{
		success: true
		result:  result
	})
}

@['/:username/:repo_name/contributors']
pub fn (mut app App) contributors(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}

	contributors := app.find_repo_registered_contributor(repo.id)

	return $veb.html()
}

@['/:username/:repo_name/blob/:branch_name/:path...']
pub fn (mut app App) blob(mut ctx Context, username string, repo_name string, branch_name string, path string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}

	mut path_parts := path.split('/')
	path_parts.pop()

	ctx.current_path = path
	ctx.path_split = [repo_name]
	ctx.path_split << path_parts

	if !app.contains_repo_branch(repo.id, branch_name) && branch_name != repo.primary_branch {
		app.info('Branch ${branch_name} not found')
		return ctx.not_found()
	}

	raw_url := '/${username}/${repo_name}/raw/${branch_name}/${path}'
	file := app.find_repo_file_by_path(repo.id, branch_name, path) or {
		repo.lookup_file_via_git(branch_name, path) or { return ctx.not_found() }
	}
	is_markdown := file.name.to_lower().ends_with('.md')
	plain_text := repo.read_file(branch_name, path)
	highlighted_source, _, _ := highlight.highlight_text(plain_text, file.name, false)
	source := veb.RawHtml(highlighted_source)
	loc, sloc := calculate_lines_of_code(plain_text)

	return $veb.html()
}

@['/:user/:repository/raw/:branch_name/:path...']
pub fn (mut app App) handle_raw(mut ctx Context, username string, repo_name string, branch_name string, path string) veb.Result {
	user := app.get_user_by_username(username) or { return ctx.not_found() }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}

	// TODO: throw error when git returns non-zero status
	file_source := repo.git('--no-pager show ${branch_name}:${path}')

	return ctx.ok(file_source)
}
