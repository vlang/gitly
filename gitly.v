// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import time
import os
import log
import hl
import crypto.sha1
import sqlite
import math

const (
	commits_per_page   = 35
	http_port          = 8080
	expire_length      = 200
	posts_per_day      = 5
	max_username_len   = 32
	max_login_attempts = 5
	max_user_repos     = 10
	max_repo_name_len  = 20
	max_namechanges    = 3
	namechange_period  = time.hour * 24
)

struct App {
	vweb.Context
pub mut:
	db sqlite.DB
mut:
	started_at    u64
	path          string // current path being viewed
	repo          Repo
	version       string
	html_path     vweb.RawHtml
	page_gen_time string
	is_tree       bool
	show_menu     bool
	settings      GitlySettings
	file_log      log.Log
	cli_log       log.Log
	logged_in     bool
	user          User
	path_splt     []string
	branch        string
	// form_error string
}

// fn C.sqlite3_threadsafe() int
fn C.sqlite3_config(int)

fn main() {
	C.sqlite3_config(3) // thread safe sqlite
	vweb.run(new_app(), http_port)
}

fn new_app() &App {
	mut app := &App{
		db: sqlite.connect('gitly.sqlite') or {
			println('failed to connect to db')
			panic(err)
		}
		started_at: time.now().unix
	}
	app.create_tables()

	///////////////

	if !os.is_dir('logs') {
		os.mkdir('logs') or { panic('cannot create folder logs') }
	}
	app.file_log.set_level(.info)
	app.cli_log.set_level(.info)
	now := time.now()
	app.file_log.set_full_logpath('./logs/log_${now.ymmdd()}.log')
	// app.info('init_once()')
	mut version := os.read_file('static/assets/version') or { 'unknown' }
	result := os.execute('git rev-parse --short HEAD')
	if result.exit_code == 0 && !result.output.contains('fatal') {
		version = result.output.trim_space()
	}
	if version != app.version {
		os.write_file('static/assets/version', app.version) or { panic(err) }
	}
	app.version = version
	app.serve_static('/gitly.css', 'static/css/gitly.css') //, 'text/css')
	app.serve_static('/jquery.js', 'static/js/jquery.js') //, 'text/javascript')
	app.serve_static('/favicon.svg', 'static/assets/favicon.svg') //, 'image/svg+xml')
	app.serve_static('/robots.txt', 'static/robots.txt') //, 'image/svg+xml')
	/*
	app.db = sqlite.connect('gitly.sqlite') or {
		println('failed to connect to db')
		panic(err)
	}
	app.create_tables()
	*/
	/*
	app.oauth_client_id = os.getenv('GITLY_OAUTH_CLIENT_ID')
	app.oauth_client_secret = os.getenv('GITLY_OAUTH_SECRET')
	if app.oauth_client_id == '' {
		app.get_oauth_tokens_from_db()
	}
	*/
	app.load_settings()
	if !os.exists(app.settings.repo_storage_path) {
		os.mkdir(app.settings.repo_storage_path) or {
			app.info('Failed to create $app.settings.repo_storage_path')
			app.info('Error: $err')
			exit(1)
		}
	}
	// Create the first admin user if the db is empty
	app.find_user_by_id(1) or {
		app.settings.only_gh_login = false // allow admin to register
		/*
		println('Creating admin...')
		user := User{
			name: 'admin'
			username: 'admin'
			password: 'admin'
		}
		app.insert_user(user)
		new_user := app.find_user_by_id(1) or {
			println('Failed to create an admin user')
			exit(1)
		}
		println('new user=')
		println(new_user)
		app.auth_user(new_user)
		*/
	}
	// go app.create_new_test_repo() // if it doesn't exist
	if '-cmdapi' in os.args {
		go app.command_fetcher()
	}

	/////////////
	return app
}

pub fn (mut app App) info(msg string) { // vweb.Result {
	app.file_log.info(msg)
	app.cli_log.info(msg)
	// return app.text('ok')
}

pub fn (mut app App) warn(msg string) { // vweb.Result {
	app.file_log.warn(msg)
	app.cli_log.warn(msg)
	println(msg)
	// return app.text('ok2')
}

/*
pub fn (mut app App) error(msg string) {
	app.file_log.error(msg)
	app.cli_log.error(msg)
	//app.form_error = msg
}
*/
pub fn (mut app App) init_server() {
}

pub fn (mut app App) before_request() {
	url := app.req.url
	println('\n\nbefore_request() url=$url')
	// app.info('path=$app.path')
	app.logged_in = app.is_logged_in()
	if app.logged_in {
		app.user = app.get_user_from_cookies() or {
			app.logged_in = false
			User{}
		}
		app.user.b_avatar = app.user.avatar == ''
		if !app.user.b_avatar {
			app.user.avatar = app.user.username[..1]
		}
	}
	app.add_visit()
}

// Redirect to the home page
pub fn (mut app App) r_home() vweb.Result {
	return app.redirect('/')
}

// Redirect to the current repo main site
pub fn (mut app App) r_repo() vweb.Result {
	return app.redirect('/$app.user.username/$app.repo.name')
}

/*
pub fn (mut app App) create_new_test_repo() {
	if x := app.find_repo_by_name(1, 'v') {
		app.info('test repo already exists')
		app.repo = x
		app.repo.lang_stats = app.find_repo_lang_stats(app.repo.id)
		// init branches list for existing repo
		app.update_repo_data(app.repo)
		return
	}
	_ := os.ls('.') or {
		return
	}
	cur_dir := os.base_dir(os.executable())
	git_dir := os.join_path(cur_dir, 'test_repo')
	app.add_user('vlang', '', ['vlang@vlang.io'], true)
	app.repo = Repo{
		name: 'v'
		user_name: 'vlang'
		git_dir: git_dir
		lang_stats: test_lang_stats
		user_id: 1
		description: 'The V programming language'
		nr_contributors: 0
		nr_open_issues: 0
		nr_open_prs: 0
		nr_commits: 0
		id: 1
	}
	app.info('inserting test repo')
	app.init_tags(app.repo)
	app.update_repo()
}
*/
['/:user/:repo/settings']
pub fn (mut app App) repo_settings(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.r_repo()
	}
	app.show_menu = true
	return $vweb.html()
}

// Helper function
fn (mut app App) repo_belongs_to(user string, repo string) bool {
	return app.logged_in && app.exists_user_repo(user, repo) && app.repo.user_id == app.user.id
}

['/:user/:repo/settings'; post]
pub fn (mut app App) update_repo_settings(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.r_repo()
	}
	if 'webhook_secret' in app.form && app.form['webhook_secret'] != app.repo.webhook_secret
		&& app.form['webhook_secret'] != '' {
		webhook := sha1.hexhash(app.form['webhook_secret'])
		app.update_repo_webhook(app.repo.id, webhook)
	}
	return app.r_repo()
}

['/:user/:repo/delete_repo'; post]
pub fn (mut app App) repo_delete(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.r_repo()
	}
	if 'verify' in app.form && app.form['verify'] == '$user/$repo' {
		go app.delete_repo(app.repo.id, app.repo.git_dir, app.repo.name)
	} else {
		app.error('Verification failed')
		return app.repo_settings(user, repo)
	}
	return app.r_home()
}

['/:user/:repo/move_repo'; post]
pub fn (mut app App) repo_move(user string, repo string) vweb.Result {
	if !app.repo_belongs_to(user, repo) {
		return app.r_repo()
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
	return app.r_home()
}

['/:user/:repo']
pub fn (mut app App) tree2(user string, repo string) vweb.Result {
	match repo {
		'repos' {
			return app.user_repos(user)
		}
		'issues' {
			return app.user_issues_0(user)
		}
		/*'prs' {
			return app.user_pullrequests(user)
		}*/
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

// pub fn (mut app App) tree(path string) {
['/:user/:repo/tree/:branch/:path...']
pub fn (mut app App) tree(user string, repo string, branch string, path string) vweb.Result {
	// println('tree')
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	_, u := app.check_username(user)
	if !app.repo.is_public {
		if u.id != app.user.id {
			return app.not_found()
		}
	}
	println('\n\n\ntree() user="$user" repo="' + repo + '"')
	app.path = '/$path'
	if app.path.contains('/favicon.svg') {
		return vweb.not_found()
	}
	app.path_splt = '$repo/$path'.split('/')
	app.is_tree = true
	app.show_menu = true
	app.branch = branch
	// t := time.ticks()
	app.inc_repo_views(app.repo.id)
	mut up := '/'
	can_up := path != ''
	if can_up {
		if path.split('/').len == 1 {
			up = '../..'
		} else {
			up = app.req.url.all_before_last('/')
		}
	}
	// println(up)
	println('path=$app.path')
	if app.path.starts_with('/') {
		app.path = app.path[1..]
	}
	mut files := app.find_repo_files(app.repo.id, branch, app.path)
	app.info('tree() nr files found: $files.len in branch $branch')
	if files.len == 0 {
		// No files in the db, fetch them from git and cache in db
		app.info('caching files, repo_id=$app.repo.id')
		t := time.ticks()
		files = app.cache_repo_files(mut app.repo, branch, app.path)
		println('caching files took ${time.ticks() - t}ms')
		go app.slow_fetch_files_info(branch, app.path)
	}
	if files.any(it.last_msg == '') {
		// If any of the files has a missing `last_msg`, we need to refetch it.
		go app.slow_fetch_files_info(branch, app.path)
	}
	mut readme := vweb.RawHtml('')
	/*
	println(files)
	for file in files {
		if file.name.to_lower() == 'readme.md' {
			blob_path := os.join_path(app.repo.git_dir, '$file.parent_path$file.name')
			plain_text := os.read_file(blob_path) or {
				''
			}
			src, _, _ := hl.highlight_text(plain_text, blob_path, false)
			readme = vweb.RawHtml(src)
		}
	}
	*/
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
	// println('app.tree() = ${time.ticks()-t}ms')
	// branches := ['master'] TODO implemented usage
	diff := int(time.ticks() - app.page_gen_start)
	if diff == 0 {
		app.page_gen_time = '<1ms'
	} else {
		app.page_gen_time = '${diff}ms'
	}
	return $vweb.html()
}

pub fn (mut app App) index() vweb.Result {
	app.show_menu = false
	// println(' all_users =$app.nr_all_users()')
	if app.nr_all_users() == 0 {
		return app.redirect('/register')
	}
	return $vweb.html()
}

['/:user/:repo/update']
pub fn (mut app App) update(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	/*
	secret := if 'X-Hub-Signature' in app.req.headers { app.req.headers['X-Hub-Signature'][5..] } else { '' }
	if secret == '' {
		return app.r_home()
	}
	if secret == app.repo.webhook_secret && app.repo.webhook_secret != '' {
		go app.update_repo_data(&app.repo)
	}
	*/
	if app.user.is_admin {
		// QTODO go
		app.update_repo_data(mut app.repo)
		app.slow_fetch_files_info('master', '.')
	}
	return app.r_repo()
}

['/new']
pub fn (mut app App) new() vweb.Result {
	if !app.logged_in {
		return app.redirect('/login')
	}
	return $vweb.html()
}

['/new'; post]
pub fn (mut app App) new_repo() vweb.Result {
	if !app.logged_in {
		return app.redirect('/login')
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
	app.insert_repo(app.repo)
	app.repo = app.find_repo_by_name(app.user.id, app.repo.name) or {
		app.info('Repo was not inserted')
		return app.redirect('/new')
	}
	// println('start go')
	/*
	if app.repo.clone_url != '' {
		println('cloning $app.repo.clone_url')
		app.repo.clone()
	}
	*/
	go app.update_repo()
	// println('end go')
	return app.redirect('/$app.user.username/repos')
}

['/:user/:repo/commits']
pub fn (mut app App) commits_0(user string, repo string) vweb.Result {
	return app.commits(user, repo, 0)
}

['/:user/:repo/commits/:page']
pub fn (mut app App) commits(user string, repo string, page int) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	app.show_menu = true
	mut commits := app.find_repo_commits_as_page(app.repo.id, page)
	mut b_author := false
	mut last := false
	mut first := false
	/*
	if args.len == 2 {
		println(typeof(args[0].int()))
		if !args[0].starts_with('&') {
			commits = app.repo.get_commits_by_year(args[0].int())
		} else {
			b_author = true
			author := args[0]
			commits = app.repo.get_commits_by_author(author[1..author.len])
		}
	} else if args.len == 3 {
		commits = app.repo.get_commits_by_year_month(args[0].int(), args[1].int())
	} else if args.len == 4 {
		commits = app.repo.get_commits_by_year_month_day(args[0].int(), args[1].int(), args[2].int())
	}
	*/
	if app.repo.nr_commits > commits_per_page {
		offset := page * commits_per_page
		delta := app.repo.nr_commits - offset
		if delta > 0 {
			if delta == app.repo.nr_commits && page == 0 {
				first = true
			} else {
				last = true
			}
		}
	} else {
		last = true
		first = true
	}
	mut last_site := 0
	if page > 0 {
		last_site = page - 1
	}
	next_site := page + 1
	mut msg := 'on'
	if b_author {
		msg = 'by'
	}
	mut d_commits := map[string][]Commit{}
	for commit in commits {
		date := time.unix(commit.created_at)
		day := date.day
		month := date.month
		year := date.year
		author := commit.author_id.str()
		date_s := '${day}.${month}.$year'
		if !b_author {
			if date_s !in d_commits {
				d_commits[date_s] = []Commit{}
			}
			d_commits[date_s] << commit
		} else {
			if author !in d_commits {
				d_commits[author] = []Commit{}
			}
			d_commits[author] << commit
		}
	}
	return $vweb.html()
}

['/:user/:repo/commit/:hash']
pub fn (mut app App) commit(user string, repo string, hash string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	app.show_menu = true
	commit := app.find_repo_commit_by_hash(app.repo.id, hash)
	changes := commit.get_changes(app.repo)
	mut all_adds := 0
	mut all_dels := 0
	mut sources := map[string]vweb.RawHtml{}
	for change in changes {
		all_adds += change.additions
		all_dels += change.deletions
		src, _, _ := hl.highlight_text(change.message, change.file, true)
		sources[change.file] = vweb.RawHtml(src)
	}
	return $vweb.html()
}

['/:user/:repo/issues']
pub fn (mut app App) issues_0(user string, repo string) vweb.Result {
	return app.issues(user, repo, 0)
}

['/:user/:repo/issues/:page']
pub fn (mut app App) issues(user string, repo string, page int) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		app.not_found()
	}
	app.show_menu = true
	mut issues := app.find_repo_issues_as_page(app.repo.id, page)
	mut first := false
	mut last := false
	for index, issue in issues {
		issues[index].author_name = app.find_username_by_id(issue.author_id)
	}
	if app.repo.nr_open_issues > commits_per_page {
		offset := page * commits_per_page
		delta := app.repo.nr_open_issues - offset
		if delta > 0 {
			if delta == app.repo.nr_open_issues && page == 0 {
				first = true
			} else {
				last = true
			}
		}
	} else {
		last = true
		first = true
	}
	mut last_site := 0
	if page > 0 {
		last_site = page - 1
	}
	next_site := page + 1
	return $vweb.html()
}

['/:user/:repo/issue/:id']
pub fn (mut app App) issue(user string, repo string, id_str string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	app.show_menu = true
	mut id := 1
	if id_str != '' {
		id = id_str.int()
	}
	issue0 := app.find_issue_by_id(id) or { return app.not_found() }
	mut issue := issue0 // TODO bug with optionals (.data)
	issue.author_name = app.find_username_by_id(issue.author_id)
	comments := app.find_issue_comments(issue.id)
	return $vweb.html()
}

['/:user/:repo/pull/:id']
pub fn (mut app App) pull(user string, repo string, id_str string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	_ := app.path.split('/')
	id := 0
	pr0 := app.find_pr_by_id(id) or { return app.not_found() }
	pr := pr0
	comments := app.find_issue_comments(pr.id)
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

['/:user/:repo/branches']
pub fn (mut app App) branches(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	app.show_menu = true
	mut branches := app.find_repo_branches(app.repo.id)
	return $vweb.html()
}

['/:user/:repo/releases']
pub fn (mut app App) releases(user_str string, repo string) vweb.Result {
	if !app.exists_user_repo(user_str, repo) {
		return app.not_found()
	}
	app.show_menu = true
	mut releases := []Release{}
	mut release := Release{}
	tags := app.find_repo_tags(app.repo.id)
	rels := app.find_repo_releases(app.repo.id)
	users := app.find_repo_registered_contributor(app.repo.id)
	for rel in rels {
		release.notes = rel.notes
		mut user_id := 0
		for tag in tags {
			if tag.id == rel.tag_id {
				release.tag_name = tag.name
				release.tag_hash = tag.hash
				release.date = time.unix(tag.date)
				user_id = tag.user_id
				break
			}
		}
		for user in users {
			if user.id == user_id {
				release.user = user.username
				break
			}
		}
		releases << release
	}
	return $vweb.html()
}

['/:user/:repo/blob/:branch/:path...']
pub fn (mut app App) blob(user string, repo string, branch string, path string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	app.path = path
	app.path_splt = '$repo/$path'.split('/')
	app.path_splt = app.path_splt[..app.path_splt.len - 1]
	if !app.contains_repo_branch(branch, app.repo.id) && branch != app.repo.primary_branch {
		app.info('Branch $branch not found')
		return app.not_found()
	}
	mut raw := false
	if app.path.ends_with('/raw') {
		app.path = app.path.substr(0, app.path.len - 4)
		raw = true
	}
	mut blob_path := os.join_path(app.repo.git_dir, app.path)
	// mut plain_text := ''
	// println(blob_path)
	/*
	if branch == app.repo.primary_branch {
		//plain_text = os.read_file(path) or { 'Error' }
	} else {
	*/
	plain_text := app.repo.git('--no-pager show $branch:$app.path')
	// }
	mut source := vweb.RawHtml(plain_text.str())
	// mut source := (plain_text.str())
	if os.file_size(blob_path) < 1000000 {
		if !raw {
			src, _, _ := hl.highlight_text(plain_text, blob_path, false)
			source = vweb.RawHtml(src)
		}
	}
	// Increase file's number of views
	/*
	file := app.find_file_by_path(app.repo.id, 'master', blob_path) or {
		println('FILE NOT FOUND')
		return vweb.Result{}
	}
	println('BLOB file $file.name')
	app.inc_file_views(file.id)
	*/
	return $vweb.html()
}

['/:user/:repo/issues/new']
pub fn (mut app App) new_issue(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	if !app.logged_in {
		return app.not_found()
	}
	app.show_menu = true
	return $vweb.html()
}

['/:user/:repo/issues/new'; post]
pub fn (mut app App) add_issue(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	if !app.logged_in || (app.logged_in && app.user.nr_posts >= posts_per_day) {
		return app.r_home()
	}
	title := app.form['title'] // TODO use fn args
	text := app.form['text']
	if title == '' || text == '' {
		return app.redirect('/$user/$repo/new_issue')
	}
	issue := Issue{
		title: title
		text: text
		repo_id: app.repo.id
		author_id: app.user.id
		created_at: int(time.now().unix)
	}
	app.inc_user_post(mut app.user)
	app.insert_issue(issue)
	app.inc_repo_issues(app.repo.id)
	return app.redirect('/$user/$repo/issues')
}

['/:user/:repo/comment'; post]
pub fn (mut app App) add_comment(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	text := app.form['text']
	issue_id := app.form['issue_id']
	if text == '' || issue_id == '' || !app.logged_in {
		return app.redirect('/$user/$repo/issue/$issue_id')
	}
	comm := Comment{
		author_id: app.user.id
		issue_id: issue_id.int()
		created_at: int(time.now().unix)
		text: text
	}
	app.insert_comment(comm)
	app.inc_issue_comments(comm.issue_id)
	return app.redirect('/$user/$repo/issue/$issue_id')
}

fn (mut app App) rename_user_dir(old_name string, new_name string) {
	os.mv('$app.settings.repo_storage_path/$old_name', '$app.settings.repo_storage_path/$new_name') or {
		panic(err)
	}
}

pub fn (mut app App) running_since() string {
	dur := time.now().unix - app.started_at
	seconds := dur % 60
	minutes := int(math.floor(dur / 60)) % 60
	hours := int(math.floor(minutes / 60)) % 24
	days := int(math.floor(hours / 24))
	return '$days days $hours hours $minutes minutes and $seconds seconds'
}

pub fn (mut app App) make_path(i int) string {
	if i == 0 {
		return app.path_splt[..i + 1].join('/')
	}
	mut s := app.path_splt[0]
	s += '/tree/$app.branch/'
	s += app.path_splt[1..i + 1].join('/')
	return s
}
