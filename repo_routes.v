module main

import vweb
import crypto.sha1
import os
import highlight
import time

['/:username/repos']
pub fn (mut app App) user_repos(username string) vweb.Result {
	exists, u := app.check_username(username)
	if !exists {
		return app.not_found()
	}
	user := u
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
pub fn (mut app App) handle_update_repo_settings(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.redirect_to_current_repository()
	}
	if 'webhook_secret' in app.form && app.form['webhook_secret'] != app.repo.webhook_secret
		&& app.form['webhook_secret'] != '' {
		webhook := sha1.hexhash(app.form['webhook_secret'])
		app.update_repo_webhook(app.repo.id, webhook)
	}
	return app.redirect_to_current_repository()
}

['/:user/:repo'; delete]
pub fn (mut app App) handle_repo_delete(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.redirect_to_current_repository()
	}
	if 'verify' in app.form && app.form['verify'] == '$user/$repo' {
		go app.delete_repo(app.repo.id, app.repo.git_dir, app.repo.name)
	} else {
		app.error('Verification failed')
		return app.repo_settings(user, repo)
	}
	return app.redirect_to_index()
}

['/:user/:repo/move'; post]
pub fn (mut app App) handle_repo_move(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.redirect_to_current_repository()
	}
	if 'verify' in app.form && 'dest' in app.form && app.form['verify'] == '$user/$repo' {
		uname := app.form['dest']
		dest_user := app.find_user_by_username(uname) or {
			app.error('Unknown user $uname')
			return app.repo_settings(user, repo)
		}
		if app.user_has_repo(dest_user.id, app.repo.name) {
			app.error('User already owns repo $app.repo.name')
			return app.repo_settings(user, repo)
		}
		if app.nr_user_repos(dest_user.id) >= max_user_repos {
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

['/:user/:repo/update']
pub fn (mut app App) handle_repo_update(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	if app.user.is_admin {
		app.update_repo_data(mut app.repo)
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
pub fn (mut app App) handle_new_repo() vweb.Result {
	if !app.logged_in {
		return app.redirect_to_login()
	}
	if app.nr_user_repos(app.user.id) >= max_user_repos {
		app.error('You have reached the limit for the number of repositories')
		return app.new()
	}
	name := app.form['name']
	if name.len > max_repo_name_len {
		app.error('Repository name is too long (should be fewer than $max_repo_name_len characters)')
		return app.new()
	}
	if app.exists_user_repo(app.user.username, name) {
		app.error('A repository with the name "$name" already exists')
		return app.new()
	}
	if name.contains(' ') {
		app.error('Repo name cannot contain spaces')
		return app.new()
	}
	mut clone_url := app.form['clone_url']
	if !clone_url.starts_with('https://') {
		clone_url = 'https://' + clone_url
	}
	app.repo = Repo{
		name: name
		git_dir: os.join_path(app.settings.repo_storage_path, app.user.username, name)
		user_id: app.user.id
		primary_branch: 'master'
		user_name: app.user.username
		clone_url: clone_url
	}
	if app.repo.clone_url == '' {
		os.mkdir(app.repo.git_dir) or { panic(err) }
		app.repo.git('init')
	} else {
		app.repo.clone()
	}

	app.add_repo(app.repo)

	app.repo = app.find_repo_by_name(app.user.id, app.repo.name) or {
		app.info('Repo was not inserted')
		return app.redirect('/new')
	}

	go app.update_repo()

	return app.redirect('/$app.user.username/repos')
}

['/:user/:repo/tree/:branch/:path...']
pub fn (mut app App) tree(user string, repo string, branch string, path string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	_, u := app.check_username(user)
	if !app.repo.is_public {
		if u.id != app.user.id {
			return app.not_found()
		}
	}

	app.current_path = '/$path'
	if app.current_path.contains('/favicon.svg') {
		return vweb.not_found()
	}

	app.path_split = '$repo/$path'.split('/')
	app.is_tree = true
	app.show_menu = true
	app.branch = branch

	app.increment_repo_views(app.repo.id)
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
	mut files := app.find_repo_files(app.repo.id, branch, app.current_path)
	app.info('tree() nr files found: $files.len in branch $branch')
	if files.len == 0 {
		// No files in the db, fetch them from git and cache in db
		app.info('caching files, repo_id=$app.repo.id')
		t := time.ticks()
		files = app.cache_repo_files(mut app.repo, branch, app.current_path)
		println('caching files took ${time.ticks() - t}ms')
		go app.slow_fetch_files_info(branch, app.current_path)
	}

	if files.any(it.last_msg == '') {
		// If any of the files has a missing `last_msg`, we need to refetch it.
		go app.slow_fetch_files_info(branch, app.current_path)
	}

	mut readme := vweb.RawHtml('')

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
	return $vweb.html()
}

['/:user/:repo/pull/:id']
pub fn (mut app App) pull(user string, repo string, id_str string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	_ := app.current_path.split('/')
	id := 0
	pr0 := app.find_pr_by_id(id) or { return app.not_found() }
	pr := pr0

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
pub fn (mut app App) blob(user string, repo string, branch string, path string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	app.current_path = path
	app.path_split = '$repo/$path'.split('/')
	app.path_split = app.path_split[..app.path_split.len - 1]
	if !app.contains_repo_branch(app.repo.id, branch) && branch != app.repo.primary_branch {
		app.info('Branch $branch not found')
		return app.not_found()
	}
	mut raw := false
	if app.current_path.ends_with('/raw') {
		app.current_path = app.current_path.substr(0, app.current_path.len - 4)
		raw = true
	}
	mut blob_path := os.join_path(app.repo.git_dir, app.current_path)

	plain_text := app.repo.git('--no-pager show $branch:$app.current_path')

	mut source := vweb.RawHtml(plain_text.str())

	if os.file_size(blob_path) < 1000000 {
		if !raw {
			src, _, _ := highlight.highlight_text(plain_text, blob_path, false)
			source = vweb.RawHtml(src)
		}
	}

	return $vweb.html()
}
