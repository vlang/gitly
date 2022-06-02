module main

import vweb
import crypto.sha1
import os
import highlight
import time
import validation
import git

['/:username/repos']
pub fn (mut app App) user_repos(username string) vweb.Result {
	exists, user := app.check_username(username)

	if !exists {
		return app.not_found()
	}

	mut repos := app.find_user_public_repos(user.id)

	if user.id == app.user.id {
		repos = app.find_user_repos(user.id)
	}

	return $vweb.html()
}

['/:user/:repo/settings']
pub fn (mut app App) repo_settings(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.redirect_to_current_repository()
	}

	app.show_menu = true

	return $vweb.html()
}

fn (mut app App) repo_belongs_to(user string, repo string) bool {
	return app.logged_in && app.exists_user_repo(user, repo) && app.repo.user_id == app.user.id
}

['/:user/:repo/settings'; post]
pub fn (mut app App) handle_update_repo_settings(user string, repo string, webhook_secret string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.redirect_to_current_repository()
	}

	if webhook_secret != '' && webhook_secret != app.repo.webhook_secret {
		webhook := sha1.hexhash(webhook_secret)
		app.update_repo_webhook(app.repo.id, webhook)
	}

	return app.redirect_to_current_repository()
}

['/:user/:repo'; delete]
pub fn (mut app App) handle_repo_delete(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.redirect_to_current_repository()
	}

	if app.form['verify'] == '$user/$repo' {
		go app.delete_repository(app.repo.id, app.repo.git_dir, app.repo.name)
	} else {
		app.error('Verification failed')
		return app.repo_settings(user, repo)
	}

	return app.redirect_to_index()
}

['/:user/:repo/move'; post]
pub fn (mut app App) handle_repo_move(user string, repo string, dest string, verify string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.redirect_to_current_repository()
	}

	if dest != '' && verify == '$user/$repo' {
		dest_user := app.find_user_by_username(dest) or {
			app.error('Unknown user $dest')
			return app.repo_settings(user, repo)
		}

		if app.user_has_repo(dest_user.id, app.repo.name) {
			app.error('User already owns repo $app.repo.name')
			return app.repo_settings(user, repo)
		}

		if app.get_count_user_repos(dest_user.id) >= max_user_repos {
			app.error('User already reached the repo limit')
			return app.repo_settings(user, repo)
		}

		app.move_repo_to_user(app.repo.id, dest_user.id, dest_user.username)

		return app.redirect('/$dest_user.username/$app.repo.name')
	} else {
		app.error('Verification failed')

		return app.repo_settings(user, repo)
	}

	return app.redirect_to_index()
}

['/:user/:repo']
pub fn (mut app App) handle_tree(user string, repo string) vweb.Result {
	match repo {
		'repos' {
			return app.user_repos(user)
		}
		'issues' {
			return app.handle_get_user_issues(user)
		}
		'settings' {
			return app.user_settings(user)
		}
		else {}
	}

	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	return app.tree(user, repo, app.repo.primary_branch, '')
}

['/:user/:repo/tree/:branch']
pub fn (mut app App) handle_branch_tree(user string, repo string, branch string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	return app.tree(user, repo, branch, '')
}

['/:user/:repo/update']
pub fn (mut app App) handle_repo_update(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	if app.user.is_admin {
		app.update_repository_data(mut app.repo)
		app.slow_fetch_files_info('master', '.')
	}

	return app.redirect_to_current_repository()
}

['/new']
pub fn (mut app App) new() vweb.Result {
	if !app.logged_in {
		return app.redirect_to_login()
	}

	return $vweb.html()
}

['/new'; post]
pub fn (mut app App) handle_new_repo(name string, clone_url string) vweb.Result {
	mut valid_clone_url := clone_url
	is_clone_url_empty := validation.is_string_empty(clone_url)
	is_public := app.form['is_private'] != 'on'

	if !app.logged_in {
		return app.redirect_to_login()
	}

	if app.get_count_user_repos(app.user.id) >= max_user_repos {
		app.error('You have reached the limit for the number of repositories')

		return app.new()
	}

	if name.len > max_repo_name_len {
		app.error('Repository name is too long (should be fewer than $max_repo_name_len characters)')
		return app.new()
	}

	if app.exists_user_repo(app.user.username, name) {
		app.error('A repository with the name "$name" already exists')
		return app.new()
	}

	if name.contains(' ') {
		app.error('Repository name cannot contain spaces')
		return app.new()
	}

	is_repository_name_valid := validation.is_repository_name_valid(name)

	if !is_repository_name_valid {
		app.error('Repository name is not valid')

		return app.new()
	}

	has_clone_url_https_prefix := clone_url.starts_with('https://')

	if !is_clone_url_empty && !has_clone_url_https_prefix {
		valid_clone_url = 'https://' + clone_url
	}

	repository_path := os.join_path(app.settings.repo_storage_path, app.user.username,
		name)

	app.repo = Repo{
		name: name
		git_dir: repository_path
		user_id: app.user.id
		primary_branch: 'master'
		user_name: app.user.username
		clone_url: valid_clone_url
		is_public: is_public
	}

	if is_clone_url_empty {
		os.mkdir(app.repo.git_dir) or { panic(err) }

		app.repo.git('init --bare')
	} else {
		app.repo.clone()
	}

	app.add_repo(app.repo)

	app.repo = app.find_repo_by_name(app.user.id, app.repo.name) or {
		app.info('Repo was not inserted')

		return app.redirect('/new')
	}

	repository_id := app.repo.id

	primary_branch := git.get_repository_primary_branch(repository_path)
	app.update_repo_primary_branch(repository_id, primary_branch)

	app.repo = app.find_repo_by_id(repository_id)

	// Update only cloned repositories
	if !is_clone_url_empty {
		app.update_repository(mut app.repo)
	}

	return app.redirect('/$app.user.username/repos')
}

['/:user/:repository/tree/:branch/:path...']
pub fn (mut app App) tree(username string, repository_name string, branch string, path string) vweb.Result {
	if !app.exists_user_repo(username, repository_name) {
		return app.not_found()
	}

	_, user := app.check_username(username)
	if !app.repo.is_public {
		if user.id != app.user.id {
			return app.not_found()
		}
	}

	repo_id := app.repo.id
	log_prefix := '$username/$repository_name'

	app.current_path = '/$path'
	if app.current_path.contains('/favicon.svg') {
		return vweb.not_found()
	}

	path_parts := path.split('/')

	app.path_split = [repository_name]
	app.path_split << path_parts

	app.is_tree = true
	app.show_menu = true
	app.branch = branch

	app.increment_repo_views(repo_id)
	mut up := '/'
	can_up := path != ''
	if can_up {
		if path.split('/').len == 1 {
			up = '../..'
		} else {
			up = app.req.url.all_before_last('/')
		}
	}

	if app.current_path.starts_with('/') {
		app.current_path = app.current_path[1..]
	}

	mut items := app.find_repository_items(repo_id, branch, app.current_path)

	app.info('$log_prefix: $items.len items found in branch $branch')

	if items.len == 0 {
		// No files in the db, fetch them from git and cache in db
		app.info('$log_prefix: caching items in repository with $repo_id')

		items = app.cache_repository_items(mut app.repo, branch, app.current_path)
		app.slow_fetch_files_info(branch, app.current_path)
	}

	if items.any(it.last_msg == '') {
		// If any of the files has a missing `last_msg`, we need to refetch it.
		app.slow_fetch_files_info(branch, app.current_path)
	}

	mut readme := vweb.RawHtml('')
	readme_file := find_readme_file(items) or { File{} }

	if readme_file.id != 0 {
		readme_path := '$path/$readme_file.name'
		readme_content := app.repo.read_file(branch, readme_path)
		highlighted_readme, _, _ := highlight.highlight_text(readme_content, readme_path,
			false)

		readme = vweb.RawHtml(highlighted_readme)
	}

	// Fetch last commit message for this directory, printed at the top of the tree
	mut last_commit := Commit{}
	if can_up {
		mut p := path
		if p.ends_with('/') {
			p = p[0..path.len - 1]
		}
		if !p.contains('/') {
			p = '/$p'
		}
		if dir := app.find_repo_file_by_path(app.repo.id, branch, p) {
			println('hash=$dir.last_hash')
			last_commit = app.find_repo_commit_by_hash(app.repo.id, dir.last_hash)
		}
	} else {
		last_commit = app.find_repo_last_commit(app.repo.id)
	}

	diff := int(time.ticks() - app.page_gen_start)
	if diff == 0 {
		app.page_gen_time = '<1ms'
	} else {
		app.page_gen_time = '${diff}ms'
	}

	// Update items after fetching info
	items = app.find_repository_items(repo_id, branch, app.current_path)

	dirs := items.filter(it.is_dir)
	files := items.filter(!it.is_dir)

	items = []
	items << dirs
	items << files

	has_commits := app.repo.commits_count > 0

	return $vweb.html()
}

['/:user/:repo/pull/:id']
pub fn (mut app App) pull(user string, repo string, id_str string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	id := 0
	pr := app.find_pr_by_id(id) or { return app.not_found() }

	comments := app.get_all_issue_comments(pr.id)
	return $vweb.html()
}

pub fn (mut app App) pulls() vweb.Result {
	prs := app.find_repo_prs(app.repo.id)

	return $vweb.html()
}

['/:user/:repo/contributors']
pub fn (mut app App) contributors(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	app.show_menu = true

	contributors := app.find_repo_registered_contributor(app.repo.id)

	return $vweb.html()
}

['/:user/:repo/blob/:branch/:path...']
pub fn (mut app App) blob(username string, repo_name string, branch string, path string) vweb.Result {
	if !app.exists_user_repo(username, repo_name) {
		return app.not_found()
	}

	mut path_parts := path.split('/')
	path_parts.pop()

	app.current_path = path
	app.path_split = [repo_name]
	app.path_split << path_parts

	app.branch = branch

	if !app.contains_repo_branch(app.repo.id, branch) && branch != app.repo.primary_branch {
		app.info('Branch $branch not found')
		return app.not_found()
	}

	raw_url := '/$username/$repo_name/raw/$branch/$path'

	blob_path := os.join_path(app.repo.git_dir, app.current_path)
	is_markdown := blob_path.to_lower().ends_with('.md')
	plain_text := app.repo.read_file(branch, app.current_path)
	highlighted_source, _, _ := highlight.highlight_text(plain_text, blob_path, false)
	source := vweb.RawHtml(highlighted_source)

	return $vweb.html()
}

['/:user/:repository/raw/:branch/:path...']
pub fn (mut app App) handle_raw(username string, repo_name string, branch string, path string) vweb.Result {
	user := app.find_user_by_username(username) or { return app.not_found() }
	repository := app.find_repo_by_name(user.id, repo_name) or { return app.not_found() }

	// TODO: throw error when git returns non-zero status
	file_source := repository.git('--no-pager show $branch:$path')

	return app.ok(file_source)
}
