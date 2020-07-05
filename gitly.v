// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import time
import os
import log
import hl
import sqlite
import math
import rand

const (
	commits_per_page   = 35
	http_port          = 8080
	expire_length      = 200
	posts_per_day      = 5
	max_username_len   = 32
	max_login_attempts = 5
	repo_storage_path  = './repos'
)

struct App {
mut:
	path                string // current path being viewed
	branch              string
	repo                Repo
	version             string
	html_path           vweb.RawHtml
	page_gen_time       string
	is_tree             bool
	show_menu           bool
	oauth_client_id     string
	oauth_client_secret string
	only_gh_login       bool
pub mut:
	file_log            log.Log
	cli_log             log.Log
	vweb                vweb.Context
	db                  sqlite.DB
	logged_in           bool
	user                User
}

fn main() {
	vweb.run<App>(http_port)
}

pub fn (mut app App) info(msg string) {
	app.file_log.info(msg)
	app.cli_log.info(msg)
}

pub fn (mut app App) warn(msg string) {
	app.file_log.warn(msg)
	app.cli_log.warn(msg)
}

pub fn (mut app App) error(msg string) {
	app.file_log.error(msg)
	app.cli_log.error(msg)
}

pub fn (mut app App) init_once() {
	os.mkdir('logs')
	app.file_log = log.Log{}
	app.cli_log = log.Log{}
	app.file_log.set_level(.info)
	app.cli_log.set_level(.info)
	date := time.now()
	date_s := '$date.ymmdd()'
	app.file_log.set_full_logpath('./logs/log_${date_s}.log')
	app.info('init_once()')
	version := os.read_file('static/assets/version') or {
		'unknown'
	}
	result := os.exec('git rev-parse --short HEAD') or {
		os.Result{
			output: version
		}
	}
	if !result.output.contains('fatal') {
		app.version = result.output.trim_space()
	}
	if version != app.version {
		os.write_file('static/assets/version', app.version)
	}
	app.path = ''
	app.branch = ''
	app.vweb.serve_static('/gitly.css', 'static/css/gitly.css', 'text/css')
	app.vweb.serve_static('/jquery.js', 'static/js/jquery.js', 'text/javascript')
	app.vweb.serve_static('/favicon.svg', 'static/assets/favicon.svg', 'image/svg+xml')
	app.db = sqlite.connect('gitly.sqlite') or {
		println('failed to connect to db')
		panic(err)
	}
	app.create_tables()
	app.oauth_client_id = os.getenv('GITLY_OAUTH_CLIENT_ID')
	app.oauth_client_secret = os.getenv('GITLY_OAUTH_SECRET')
	if app.oauth_client_id == '' {
		app.get_oauth_tokens_from_db()
	}
	if !os.exists(repo_storage_path) {
		os.mkdir(repo_storage_path) or {
			app.error('Failed to create $repo_storage_path')
			app.error('Error: $err')
			exit(1)
		}
	}
	// Create the first admin user if the db is empty
	app.find_user_by_id(1) or {
		app.only_gh_login = false // allow admin to register
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
}

pub fn (mut app App) init() {
	url := app.vweb.req.url
	app.page_gen_time = ''
	app.info('\n\ninit() url=$url')
	if url.contains('/tree/') {
		app.path = url.after('/tree/')
	} else if url.contains('/blob/') {
		app.path = url.after('/blob/')
	} else if url.contains('/pull/') {
		app.path = url.after('/pull/')
	} else {
		app.path = ''
	}
	app.branch = 'master'
	app.html_path = app.repo.html_path_to(app.path, app.branch)
	app.info('path=$app.path')
	app.logged_in = app.logged_in()
	if app.logged_in {
		app.user = app.get_user_from_cookies() or {
			app.logged_in = false
			User{}
		}
	}
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
// pub fn (mut app App) tree(path string) {
['/:user/:repo/tree']
pub fn (mut app App) tree(user, repo string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	println('\n\n\ntree() user="$user" repo="' + repo + '"')
	if app.path.contains('/favicon.svg') {
		return vweb.not_found()
	}
	app.is_tree = true
	app.show_menu = true
	// t := time.ticks()
	app.inc_repo_views(app.repo.id)
	mut up := '/'
	can_up := app.path != ''
	if can_up {
		up = app.vweb.req.url.all_before_last('/')
	}
	println('path=$app.path')
	if app.path.starts_with('/') {
		app.path = app.path[1..]
	}
	mut files := app.find_repo_files(app.repo.id, 'master', app.path)
	app.info('tree() nr files found: $files.len')
	if files.len == 0 {
		// No files in the db, fetch them from git and cache in db
		app.info('caching files, repo_id=$app.repo.id')
		t := time.ticks()
		files = app.cache_repo_files(mut app.repo, 'master', app.path)
		println('caching files took ${time.ticks()-t}ms')
		go app.slow_fetch_files_info('master', app.path)
	}
	mut readme := vweb.RawHtml('')
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
	// Fetch last commit message for this directory, printed at the top of the tree
	mut last_commit := Commit{}
	if can_up {
		mut path := app.path
		if path.ends_with('/') {
			path = path[0..path.len - 1]
		}
		if !path.contains('/') {
			path = '/$path'
		}
		if dir := app.find_repo_file_by_path(app.repo.id, 'master', path) {
			println('hash=$dir.last_hash')
			last_commit = app.find_repo_commit_by_hash(app.repo.id, dir.last_hash)
		}
	} else {
		last_commit = app.find_repo_last_commit(app.repo.id)
	}
	// println('app.tree() = ${time.ticks()-t}ms')
	// branches := ['master'] TODO implemented usage
	diff := int(time.ticks() - app.vweb.page_gen_start)
	if diff == 0 {
		app.page_gen_time = '<1ms'
	} else {
		app.page_gen_time = '${diff}ms'
	}
	return $vweb.html()
}

pub fn (mut app App) index() vweb.Result {
	app.show_menu = false
	// app.tree('','')
	return $vweb.html()
}

['/:user/:repo/update']
pub fn (mut app App) update(user, repo string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	secret := app.vweb.req.headers['X-Hub-Signature'][5..]
	if secret == app.repo.webhook_secret && app.repo.webhook_secret != '' {
		go app.update_repo_data(&app.repo)
	}
	return app.vweb.redirect('/')
}

['/:username']
pub fn (mut app App) user(username string) vweb.Result {
	app.show_menu = false
	mut user := User{}
	if username.len != 0 {
		user = app.find_user_by_username(username) or {
			return app.vweb.not_found()
		}
	} else {
		return app.vweb.not_found()
	}
	user.b_avatar = user.avatar != ''
	if !user.b_avatar {
		user.avatar = user.username.bytes()[0].str()
	}
	repos := app.find_user_repos(user.id)
	return $vweb.html()
}

['/:user/:repo/commits/:page_str']
pub fn (mut app App) commits(user, repo, page_str string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	app.show_menu = true
	page := if page_str.len >= 1 { page_str.int() } else { 0 }
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
pub fn (mut app App) commit(user, repo, hash string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
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

['/:user/:repo/issues/:page_str']
pub fn (mut app App) issues(user, repo, page_str string) vweb.Result {
	if !app.find_repo(user, repo) {
		app.vweb.not_found()
	}
	page := if page_str.len >= 1 { page_str.int() } else { 0 }
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
pub fn (mut app App) issue(user, repo, id_str string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	mut id := 1
	if id_str != '' {
		id = id_str.int()
	}
	issue0 := app.find_issue_by_id(id) or {
		return app.vweb.not_found()
	}
	mut issue := issue0 // TODO bug with optionals (.data)
	issue.author_name = app.find_username_by_id(issue.author_id)
	comments := app.find_issue_comments(issue.id)
	return $vweb.html()
}

['/:user/:repo/pull/:id']
pub fn (mut app App) pull(user, repo, id_str string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	_ := app.path.split('/')
	id := 0
	pr0 := app.find_pr_by_id(id) or {
		return app.vweb.not_found()
	}
	pr := pr0
	comments := app.find_issue_comments(pr.id)
	return $vweb.html()
}

pub fn (mut app App) pulls() vweb.Result {
	prs := app.find_repo_prs(app.repo.id)
	return $vweb.html()
}

['/:user/:repo/contributors']
pub fn (mut app App) contributors(user, repo string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	contributors := app.find_repo_registered_contributor(app.repo.id)
	return $vweb.html()
}

['/:user/:repo/branches']
pub fn (mut app App) branches(user, repo string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	app.show_menu = true
	mut branches := app.find_repo_branches(app.repo.id)
	return $vweb.html()
}

['/:user/:repo/releases']
pub fn (mut app App) releases(user_str, repo string) vweb.Result {
	if !app.find_repo(user_str, repo) {
		return app.vweb.not_found()
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

['/:user/:repo/blob']
pub fn (mut app App) blob(user, repo string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	mut raw := false
	if app.path.ends_with('/raw') {
		app.path = app.path.substr(0, app.path.len - 4)
		raw = true
	}
	blob_path := os.join_path(app.repo.git_dir, app.path)
	plain_text := os.read_file(blob_path) or {
		app.vweb.not_found()
		return vweb.Result{}
	}
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

['/:user/:repo/new_issue']
pub fn (mut app App) new_issue(user, repo string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	if !app.logged_in {
		return app.vweb.not_found()
	}
	return $vweb.html()
}

['/:user/:repo/new_issue_post']
pub fn (mut app App) new_issue_post(user, repo string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	if !app.logged_in || (app.logged_in && app.user.nr_posts >= posts_per_day) {
		return app.vweb.redirect('/')
	}
	title := app.vweb.form['title'] // TODO use fn args
	text := app.vweb.form['text']
	if title == '' || text == '' {
		return app.vweb.redirect('/$user/$repo/new_issue')
	}
	issue := Issue{
		title: title
		text: text
		repo_id: app.repo.id
		author_id: app.user.id
		created_at: int(time.now().unix)
	}
	app.inc_user_post(app.user)
	app.insert_issue(issue)
	app.inc_repo_issues(app.repo.id)
	return app.vweb.redirect('/$user/$repo/issues/0')
}

['/:user/:repo/comment_post']
pub fn (mut app App) comment_post(user, repo string) vweb.Result {
	if !app.find_repo(user, repo) {
		return app.vweb.not_found()
	}
	text := app.vweb.form['text']
	issue_id := app.vweb.form['issue_id']
	if text == '' || issue_id == '' || !app.logged_in {
		return app.vweb.redirect('/$user/$repo/issue/$issue_id')
	}
	comm := Comment{
		author_id: app.user.id
		issue_id: issue_id.int()
		created_at: int(time.now().unix)
		text: text
	}
	app.insert_comment(comm)
	app.inc_issue_comments(comm.issue_id)
	return app.vweb.redirect('/$user/$repo/issue/$issue_id')
}

pub fn (mut app App) new() vweb.Result {
	if !app.logged_in {
		return app.vweb.redirect('/login')
	}
	return $vweb.html()
}

pub fn (mut app App) new_post() vweb.Result {
	if !app.logged_in {
		return app.vweb.redirect('/login')
	}
	name := app.vweb.form['name']
	new_repo := Repo{
		name: name
		user_id: app.user.id
		user_name: app.user.username
	}
	app.insert_repo(new_repo)
	return app.vweb.redirect('/$app.user.username')
}
