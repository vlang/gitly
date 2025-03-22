module main

import veb
import crypto.sha1
import os
import highlight
import time
import validation
import git

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

	return $veb.html()
}

@['/:username/stars']
pub fn (mut app App) user_stars(username string) veb.Result {
	exists, user := app.check_username(username)

	if !exists {
		return ctx.not_found()
	}

	repos := app.find_user_starred_repos(ctx.user.id)

	return $veb.html()
}

@['/:username/:repo_name/settings']
pub fn (mut app App) repo_settings(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.redirect_to_repository(username, repo_name)
	}
	is_owner := app.check_repo_owner(ctx.user.username, repo_name)

	if !is_owner {
		return ctx.redirect_to_repository(username, repo_name)
	}

	return $veb.html()
}

@['/:username/:repo_name/settings'; post]
pub fn (mut app App) handle_update_repo_settings(username string, repo_name string, webhook_secret string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.redirect_to_repository(username, repo_name)
	}
	is_owner := app.check_repo_owner(ctx.user.username, repo_name)

	if !is_owner {
		return ctx.redirect_to_repository(username, repo_name)
	}

	if webhook_secret != '' && webhook_secret != repo.webhook_secret {
		webhook := sha1.hexhash(webhook_secret)
		app.set_repo_webhook_secret(repo.id, webhook) or { app.info(err.str()) }
	}

	return ctx.redirect_to_repository(username, repo_name)
}

@['/:user/:repo_name/delete'; post]
pub fn (mut app App) handle_repo_delete(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.redirect_to_repository(username, repo_name)
	}
	is_owner := app.check_repo_owner(ctx.user.username, repo_name)

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
	is_owner := app.check_repo_owner(ctx.user.username, repo_name)

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
	println('handle tree()')
	match repo_name {
		'repos' {
			return app.user_repos(mut ctx, username)
		}
		'issues' {
			return app.handle_get_user_issues(mut ctx, username)
		}
		'settings' {
			return app.user_settings(mut ctx, username)
		}
		else {}
	}

	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	dump(repo)
	return app.tree(mut ctx, username, repo_name, repo.primary_branch, '')
	// return app.tree(mut ctx, username, repo_name, repo.primary_branch, repo.git_dir)
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
	return $veb.html()
}

@['/new'; post]
pub fn (mut app App) handle_new_repo(mut ctx Context, name string, clone_url string, description string, no_redirect string) veb.Result {
	mut valid_clone_url := clone_url
	is_clone_url_empty := validation.is_string_empty(clone_url)
	is_public := ctx.form['repo_visibility'] == 'public'
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	if !ctx.is_admin() && app.get_count_user_repos(ctx.user.id) >= max_user_repos {
		ctx.error('You have reached the limit for the number of repositories')
		return app.new(mut ctx)
	}
	if name.len > max_repo_name_len {
		ctx.error('The repository name is too long (should be fewer than ${max_repo_name_len} characters)')
		return app.new(mut ctx)
	}
	if _ := app.find_repo_by_name_and_username(name, ctx.user.username) {
		ctx.error('A repository with the name "${name}" already exists')
		return app.new(mut ctx)
	}
	if name.contains(' ') {
		ctx.error('Repository name cannot contain spaces')
		return app.new(mut ctx)
	}
	is_repo_name_valid := validation.is_repository_name_valid(name)
	if !is_repo_name_valid {
		ctx.error('The repository name is not valid')
		return app.new(mut ctx)
	}
	has_clone_url_https_prefix := clone_url.starts_with('https://')
	if !is_clone_url_empty {
		if !has_clone_url_https_prefix {
			valid_clone_url = 'https://' + clone_url
		}
		is_git_repo := git.check_git_repo_url(valid_clone_url)
		if !is_git_repo {
			ctx.error('The repository URL does not contain any git repository or the server does not respond')
			return app.new(mut ctx)
		}
	}
	repo_path := os.join_path(app.config.repo_storage_path, ctx.user.username, name)
	mut new_repo := &Repo{
		git_repo:       git.new_repo(repo_path)
		name:           name
		description:    description
		git_dir:        repo_path
		user_id:        ctx.user.id
		primary_branch: 'master'
		user_name:      ctx.user.username
		clone_url:      valid_clone_url
		is_public:      is_public
	}
	if is_clone_url_empty {
		os.mkdir(new_repo.git_dir) or { panic(err) }
		new_repo.git('init --bare')
	} else {
		println('GO CLONING:')
		// t := time.now()

		spawn app.foo(mut new_repo)
		// new_repo.clone()
		// println(time.since(t))
	}
	app.add_repo(new_repo) or {
		ctx.error('There was an error while adding the repo')
		return app.new(mut ctx)
	}
	new_repo2 := app.find_repo_by_name_and_user_id(new_repo.name, ctx.user.id) or {
		app.info('Repo was not inserted')
		return ctx.redirect('/new')
	}
	repo_id := new_repo2.id
	// primary_branch := git.get_repository_primary_branch(repo_path)
	primary_branch := new_repo2.git_repo.primary_branch()
	dump(primary_branch)
	dump(repo_id)
	app.update_repo_primary_branch(repo_id, primary_branch) or {
		ctx.error('There was an error while adding the repo')
		return app.new(mut ctx)
	}
	app.find_repo_by_id(repo_id) or { return app.new(mut ctx) }
	// Update only cloned repositories
	/*
	if !is_clone_url_empty {
		app.update_repo_from_fs(mut new_repo) or {
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
	// dump(new_repo)
	// dump(new_repo2)
	return ctx.redirect('/${ctx.user.username}/repos')
}

pub fn (mut app App) foo(mut new_repo Repo) {
	new_repo.clone()
	println('CLONING DONE')
	app.update_repo_from_fs(mut new_repo) or {}
	// git.clone(valid_clone_url, repo_path)
}

@['/:username/:repo_name/tree/:branch_name/:path...']
pub fn (mut app App) tree(mut ctx Context, username string, repo_name string, branch_name string, path string) veb.Result {
	mut repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.not_found()
	}

	_, user := app.check_username(username)
	if !repo.is_public {
		if user.id != ctx.user.id {
			return ctx.not_found()
		}
	}

	repo_id := repo.id
	log_prefix := '${username}/${repo_name}'

	// XTODO
	// app.fetch_tags(repo) or { app.info(err.str()) }

	ctx.current_path = '/${path}'
	// if ctx.current_path.starts_with('.') {
	// 	ctx.current_path = ctx.current_path[1..]
	// }
	if ctx.current_path.contains('/favicon.svg') {
		return ctx.not_found()
	}

	path_parts := path.split('/')

	ctx.path_split = [repo_name]
	ctx.path_split << path_parts

	ctx.is_tree = true

	app.increment_repo_views(repo.id) or { app.info(err.str()) }

	mut up := '/'
	can_up := path != ''
	if can_up {
		if path.split('/').len == 1 {
			up = '../..'
		} else {
			up = ctx.req.url.all_before_last('/')
		}
	}
	dump(up)

	if ctx.current_path.starts_with('/') {
		ctx.current_path = ctx.current_path[1..]
	}
	// dump(ctx)

	mut items := app.find_repository_items(repo_id, branch_name, ctx.current_path)
	branch := app.find_repo_branch_by_name(repo.id, branch_name)

	app.info('${log_prefix}: ${items.len} items found in branch ${branch_name}')
	println(items)

	if items.len == 0 {
		// No files in the db, fetch them from git and cache in db
		app.info('${log_prefix}: caching items in repository with ${repo_id}')

		items = app.cache_repository_items(mut repo, branch_name, ctx.current_path) or {
			app.info(err.str())
			[]File{}
		}
		app.slow_fetch_files_info(mut repo, branch_name, ctx.current_path) or {
			app.info(err.str())
		}
	}

	if items.any(it.last_msg == '') {
		// If any of the files has a missing `last_msg`, we need to refetch it.
		println('no last msg')
		app.slow_fetch_files_info(mut repo, branch_name, ctx.current_path) or {
			app.info(err.str())
		}
	}

	// Fetch last commit message for this directory, printed at the top of the tree
	mut last_commit := Commit{}
	if can_up {
		mut p := path
		if p.ends_with('/') {
			p = p[0..path.len - 1]
		}
		if !p.contains('/') {
			p = '/${p}'
		}
		if dir := app.find_repo_file_by_path(repo.id, branch_name, p) {
			println('hash=${dir.last_hash}')
			last_commit = app.find_repo_commit_by_hash(repo.id, dir.last_hash)
		}
	} else {
		last_commit = app.find_repo_last_commit(repo.id, branch.id)
	}

	diff := int(time.ticks() - ctx.page_gen_start)
	if diff == 0 {
		ctx.page_gen_time = '<1ms'
	} else {
		ctx.page_gen_time = '${diff}ms'
	}

	// Update items after fetching info
	items = app.find_repository_items(repo_id, branch_name, ctx.current_path)
	println('new items')
	println(items)

	dirs := items.filter(it.is_dir)
	files := items.filter(!it.is_dir)

	items = []
	items << dirs
	items << files

	commits_count := app.get_repo_commit_count(repo.id, branch.id)
	has_commits := commits_count > 0

	// Get readme after updating repository
	mut readme := veb.RawHtml('')
	readme_file := find_readme_file(items) or { File{} }

	if readme_file.id != 0 {
		readme_path := '${path}/${readme_file.name}'
		readme_content := repo.read_file(branch_name, readme_path)
		highlighted_readme, _, _ := highlight.highlight_text(readme_content, readme_path,
			false)

		readme = veb.RawHtml(highlighted_readme)
	}

	license_file := find_license_file(items) or { File{} }
	mut license_file_path := ''

	if license_file.id != 0 {
		license_file_path = '/${username}/${repo_name}/blob/${branch_name}/LICENSE'
	}

	watcher_count := app.get_count_repo_watchers(repo_id)
	is_repo_starred := app.check_repo_starred(repo_id, ctx.user.id)
	is_repo_watcher := app.check_repo_watcher_status(repo_id, ctx.user.id)
	is_top_directory := ctx.current_path == ''

	return $veb.html()
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

	return ctx.json_success(is_repo_starred)
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

	return ctx.json_success(is_watching)
}

@['/:username/:repo_name/contributors']
pub fn (mut app App) contributors(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	contributors := app.find_repo_registered_contributor(repo.id)

	return $veb.html()
}

@['/:username/:repo_name/blob/:branch_name/:path...']
pub fn (mut app App) blob(mut ctx Context, username string, repo_name string, branch_name string, path string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

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
	file := app.find_repo_file_by_path(repo.id, branch_name, path) or { return ctx.not_found() }
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

	// TODO: throw error when git returns non-zero status
	file_source := repo.git('--no-pager show ${branch_name}:${path}')

	return ctx.ok(file_source)
}
