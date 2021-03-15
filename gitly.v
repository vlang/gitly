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
	max_user_repos     = 5
	max_repo_name_len  = 20
	max_namechanges    = 3
	namechange_period  = time.hour * 24
)

struct App {
mut:
	started_at    u64
	version       string
	settings      GitlySettings
	file_log      log.Log
	cli_log       log.Log
	db            sqlite.DB
	user_sessions map[string]&Session
}

fn main() {
	mut conf := vweb.Config{
		port: http_port+1
	}
	conf.serve_static('/gitly.css', 'static/css/gitly.css', 'text/css')
	conf.serve_static('/jquery.js', 'static/js/jquery.js', 'text/javascript')
	conf.serve_static('/favicon.svg', 'static/assets/favicon.svg', 'image/svg+xml')

	mut app := App{}
	app.init_once()
	vweb.run_app<App>(mut app, conf)
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
	app.started_at = time.now().unix
	if !os.is_dir('logs') {
		os.mkdir('logs') or { panic('cannot create folder logs') }
	}
	app.file_log = log.Log{}
	app.cli_log = log.Log{}
	app.file_log.set_level(.info)
	app.cli_log.set_level(.info)
	date := time.now()
	date_s := '$date.ymmdd()'
	app.file_log.set_full_logpath('./logs/log_${date_s}.log')
	//app.info('init_once()')
	version := os.read_file('static/assets/version') or { 'unknown' }
	result := os.exec('git rev-parse --short HEAD') or { os.Result{
		output: version
	} }
	if !result.output.contains('fatal') {
		app.version = result.output.trim_space()
	}
	if version != app.version {
		os.write_file('static/assets/version', app.version) or { panic(err) }
	}
	app.db = sqlite.connect('gitly.sqlite') or {
		println('failed to connect to db')
		panic(err)
	}
	app.create_tables()
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
}

// pub fn (mut app App) init() {
// 	url := app.req.url
// 	app.show_menu = false
// 	app.page_gen_time = ''
// 	app.info('\n\ninit() url=$url')
// 	app.path = ''
// 	app.logged_in = app.logged_in()
// 	app.repo = Repo{}
// 	app.user = User{}
// 	if app.logged_in {
// 		app.user = app.get_user_from_cookies() or {
// 			app.logged_in = false
// 			User{}
// 		}
// 	}
// 	app.add_visit()
// }

// Redirect to the home page
pub fn (mut app App) r_home(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	return c.redirect('/')
}

// Redirect to the current repo main site
pub fn (mut app App) r_repo(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	return c.redirect('/$sess.user.username/$sess.repo.name')
}

/*
pub fn (mut app App) create_new_test_repo() {
	mut sess := app.get_session(mut c)
	if x := app.find_repo_by_name(1, 'v') {
		app.info('test repo already exists')
		sess.repo = x
		sess.repo.lang_stats = app.find_repo_lang_stats(sess.repo.id)
		// init branches list for existing repo
		app.update_repo_data(sess.repo)
		return
	}
	_ := os.ls('.') or {
		return
	}
	cur_dir := os.base_dir(os.executable())
	git_dir := os.join_path(cur_dir, 'test_repo')
	app.add_user('vlang', '', ['vlang@vlang.io'], true)
	sess.repo = Repo{
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
	app.init_tags(sess.repo)
	app.update_repo()
}
*/
['/:user/:repo/settings']
pub fn (mut app App) repo_settings(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.repo_belongs_to(mut c, user, repo) {
		return app.r_repo(mut c)
	}
	sess.show_menu = true
	return $vweb.html()
}

// Helper function
fn (mut app App) repo_belongs_to(mut c vweb.Context, user string, repo string) bool {
	mut sess := app.get_session(mut c)
	return sess.logged_in && app.exists_user_repo(mut c, user, repo) && sess.repo.user_id == sess.user.id
}

[post]
['/:user/:repo/settings']
pub fn (mut app App) update_repo_settings(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.repo_belongs_to(mut c, user, repo) {
		return app.r_repo(mut c)
	}
	if 'webhook_secret' in c.form && c.form['webhook_secret'] != sess.repo.webhook_secret
		&& c.form['webhook_secret'] != '' {
		webhook := sha1.hexhash(c.form['webhook_secret'])
		app.update_repo_webhook(sess.repo.id, webhook)
	}
	return app.r_repo(mut c)
}

[post]
['/:user/:repo/delete_repo']
pub fn (mut app App) repo_delete(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.repo_belongs_to(mut c, user, repo) {
		return app.r_repo(mut c)
	}
	if 'verify' in c.form && c.form['verify'] == '$user/$repo' {
		go app.delete_repo(sess.repo.id, sess.repo.git_dir, sess.repo.name)
	} else {
		c.error('Verification failed')
		return app.repo_settings(mut c, user, repo)
	}
	return app.r_home(mut c)
}

[post]
['/:user/:repo/move_repo']
pub fn (mut app App) repo_move(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.repo_belongs_to(mut c, user, repo) {
		return app.r_repo(mut c)
	}
	if 'verify' in c.form && 'dest' in c.form && c.form['verify'] == '$user/$repo' {
		uname := c.form['dest']
		dest_user := app.find_user_by_username(uname) or {
			c.error('Unknown user $uname')
			return app.repo_settings(mut c, user, repo)
		}
		if app.user_has_repo(dest_user.id, sess.repo.name) {
			c.error('User already owns repo $sess.repo.name')
			return app.repo_settings(mut c, user, repo)
		}
		if app.nr_user_repos(dest_user.id) >= max_user_repos {
			c.error('User already reached the repo limit')
			return app.repo_settings(mut c, user, repo)
		}
		app.move_repo_to_user(sess.repo.id, dest_user.id, dest_user.username)
		return c.redirect('/$dest_user.username/$sess.repo.name')
	} else {
		c.error('Verification failed')
		return app.repo_settings(mut c, user, repo)
	}
	return app.r_home(mut c)
}

['/:user/:repo']
pub fn (mut app App) tree2(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	return app.tree(mut c, user, repo, sess.repo.primary_branch, '')
}

// pub fn (mut app App) tree(path string) {
['/:user/:repo/tree/:branch/:path...']
pub fn (mut app App) tree(mut c vweb.Context, user string, repo string, branch string, path string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	_, u := app.check_username(user)
	if !sess.repo.is_public {
		if u.id != sess.user.id {
			return c.not_found()
		}
	}
	println('\n\n\ntree() user="$user" repo="' + repo + '"')
	sess.path = '/$path'
	if sess.path.contains('/favicon.svg') {
		return c.not_found()
	}
	sess.is_tree = true
	sess.show_menu = true
	// t := time.ticks()
	app.inc_repo_views(sess.repo.id)
	mut up := '/'
	can_up := path != ''
	if can_up {
		up = c.req.url.all_before_last('/')
	}
	if !up.ends_with('/') {
		up += '/'
	}
	println(up)
	println('path=$sess.path')
	if sess.path.starts_with('/') {
		sess.path = sess.path[1..]
	}
	mut files := app.find_repo_files(sess.repo.id, branch, sess.path)
	app.info('tree() nr files found: $files.len in branch $branch')
	if files.len == 0 {
		// No files in the db, fetch them from git and cache in db
		app.info('caching files, repo_id=$sess.repo.id')
		t := time.ticks()
		files = app.cache_repo_files(mut sess.repo, branch, sess.path)
		println('caching files took ${time.ticks() - t}ms')
		go app.slow_fetch_files_info(mut c, branch, sess.path)
	}
	mut readme := vweb.RawHtml('')
	/*
	println(files)
	for file in files {
		if file.name.to_lower() == 'readme.md' {
			blob_path := os.join_path(sess.repo.git_dir, '$file.parent_path$file.name')
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
		if dir := app.find_repo_file_by_path(sess.repo.id, branch, p) {
			println('hash=$dir.last_hash')
			last_commit = app.find_repo_commit_by_hash(sess.repo.id, dir.last_hash)
		}
	} else {
		last_commit = app.find_repo_last_commit(sess.repo.id)
	}
	// println('app.tree() = ${time.ticks()-t}ms')
	// branches := ['master'] TODO implemented usage
	diff := int(time.ticks() - c.page_gen_start)
	if diff == 0 {
		sess.page_gen_time = '<1ms'
	} else {
		sess.page_gen_time = '${diff}ms'
	}
	return $vweb.html()
}

pub fn (mut app App) index(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	sess.show_menu = false
	// println(' all_users =$app.nr_all_users()')
	if app.nr_all_users() == 0 {
		return c.redirect('/register')
	}
	return $vweb.html()
}

['/:user/:repo/update']
pub fn (mut app App) update(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	/*
	secret := if 'X-Hub-Signature' in c.req.headers { c.req.headers['X-Hub-Signature'][5..] } else { '' }
	if secret == '' {
		return app.r_home(mut c)
	}
	if secret == sess.repo.webhook_secret && sess.repo.webhook_secret != '' {
		go app.update_repo_data(&sess.repo)
	}
	*/
	if sess.user.is_admin {
		go app.update_repo_data(mut c, sess.repo)
	}
	return app.r_repo(mut c)
}

['/new']
pub fn (mut app App) new(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	if !sess.logged_in {
		return c.redirect('/login')
	}
	return $vweb.html()
}

[post]
['/new']
pub fn (mut app App) new_repo(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	if !sess.logged_in {
		return c.redirect('/login')
	}
	if app.nr_user_repos(sess.user.id) >= max_user_repos {
		c.error('You have reached the limit for the number of repositories')
		return app.new(mut c)
	}
	name := c.form['name']
	if name.len > max_repo_name_len {
		c.error('Repository name is too long (should be fewer than $max_repo_name_len characters)')
		return app.new(mut c)
	}
	if app.exists_user_repo(mut c, sess.user.username, name) {
		c.error('A repository with the name "$name" already exists')
		return app.new(mut c)
	}
	sess.repo = Repo{
		name: name
		git_dir: os.join_path(app.settings.repo_storage_path, sess.user.username, name)
		user_id: sess.user.id
		primary_branch: 'master'
		user_name: sess.user.username
		clone_url: c.form['clone_url']
	}
	if sess.repo.clone_url == '' {
		os.mkdir(sess.repo.git_dir) or { panic(err) }
		sess.repo.git('init')
	} else {
		sess.repo.clone()
	}
	app.insert_repo(sess.repo)
	sess.repo = app.find_repo_by_name(sess.user.id, sess.repo.name) or {
		app.info('Repo was not inserted')
		return c.redirect('/new')
	}
	println('start go')
	if sess.repo.clone_url != '' {
		sess.repo.clone()
	}
	go app.update_repo(mut c)
	println('end go')
	return c.redirect('/$sess.user.username/repos')
}

['/:user/:repo/commits']
pub fn (mut app App) commits_0(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	return app.commits(mut c, user, repo, 0)
}

['/:user/:repo/commits/:page']
pub fn (mut app App) commits(mut c vweb.Context, user string, repo string, page int) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	sess.show_menu = true
	mut commits := app.find_repo_commits_as_page(sess.repo.id, page)
	mut b_author := false
	mut last := false
	mut first := false
	/*
	if args.len == 2 {
		println(typeof(args[0].int()))
		if !args[0].starts_with('&') {
			commits = sess.repo.get_commits_by_year(args[0].int())
		} else {
			b_author = true
			author := args[0]
			commits = sess.repo.get_commits_by_author(author[1..author.len])
		}
	} else if args.len == 3 {
		commits = sess.repo.get_commits_by_year_month(args[0].int(), args[1].int())
	} else if args.len == 4 {
		commits = sess.repo.get_commits_by_year_month_day(args[0].int(), args[1].int(), args[2].int())
	}
	*/
	if sess.repo.nr_commits > commits_per_page {
		offset := page * commits_per_page
		delta := sess.repo.nr_commits - offset
		if delta > 0 {
			if delta == sess.repo.nr_commits && page == 0 {
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
pub fn (mut app App) commit(mut c vweb.Context, user string, repo string, hash string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	sess.show_menu = true
	commit := app.find_repo_commit_by_hash(sess.repo.id, hash)
	changes := commit.get_changes(sess.repo)
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
pub fn (mut app App) issues_0(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	return app.issues(mut c, user, repo, 0)
}

['/:user/:repo/issues/:page']
pub fn (mut app App) issues(mut c vweb.Context, user string, repo string, page int) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		c.not_found()
	}
	sess.show_menu = true
	mut issues := app.find_repo_issues_as_page(sess.repo.id, page)
	mut first := false
	mut last := false
	for index, issue in issues {
		issues[index].author_name = app.find_username_by_id(issue.author_id)
	}
	if sess.repo.nr_open_issues > commits_per_page {
		offset := page * commits_per_page
		delta := sess.repo.nr_open_issues - offset
		if delta > 0 {
			if delta == sess.repo.nr_open_issues && page == 0 {
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
pub fn (mut app App) issue(mut c vweb.Context, user string, repo string, id_str string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	sess.show_menu = true
	mut id := 1
	if id_str != '' {
		id = id_str.int()
	}
	issue0 := app.find_issue_by_id(id) or { return c.not_found() }
	mut issue := issue0 // TODO bug with optionals (.data)
	issue.author_name = app.find_username_by_id(issue.author_id)
	comments := app.find_issue_comments(issue.id)
	return $vweb.html()
}

['/:user/:repo/pull/:id']
pub fn (mut app App) pull(mut c vweb.Context, user string, repo string, id_str string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	_ := sess.path.split('/')
	id := 0
	pr0 := app.find_pr_by_id(id) or { return c.not_found() }
	pr := pr0
	comments := app.find_issue_comments(pr.id)
	return $vweb.html()
}

pub fn (mut app App) pulls(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	prs := app.find_repo_prs(sess.repo.id)
	return $vweb.html()
}

['/:user/:repo/contributors']
pub fn (mut app App) contributors(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	sess.show_menu = true
	contributors := app.find_repo_registered_contributor(sess.repo.id)
	return $vweb.html()
}

['/:user/:repo/branches']
pub fn (mut app App) branches(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	sess.show_menu = true
	mut branches := app.find_repo_branches(sess.repo.id)
	return $vweb.html()
}

['/:user/:repo/releases']
pub fn (mut app App) releases(mut c vweb.Context, user_str string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user_str, repo) {
		return c.not_found()
	}
	sess.show_menu = true
	mut releases := []Release{}
	mut release := Release{}
	tags := app.find_repo_tags(sess.repo.id)
	rels := app.find_repo_releases(sess.repo.id)
	users := app.find_repo_registered_contributor(sess.repo.id)
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
pub fn (mut app App) blob(mut c vweb.Context, user string, repo string, branch string, path string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	sess.path = path
	if !app.contains_repo_branch(branch, sess.repo.id) && branch != sess.repo.primary_branch {
		app.info('Branch $branch not found')
		return c.not_found()
	}
	mut raw := false
	if sess.path.ends_with('/raw') {
		sess.path = sess.path.substr(0, sess.path.len - 4)
		raw = true
	}
	mut blob_path := os.join_path(sess.repo.git_dir, sess.path)
	// mut plain_text := ''
	// println(blob_path)
	/*
	if branch == sess.repo.primary_branch {
		//plain_text = os.read_file(path) or { 'Error' }
	} else {
	*/
	plain_text := sess.repo.git('--no-pager show $branch:$sess.path')
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
	file := app.find_file_by_path(sess.repo.id, 'master', blob_path) or {
		println('FILE NOT FOUND')
		return vweb.Result{}
	}
	println('BLOB file $file.name')
	app.inc_file_views(file.id)
	*/
	return $vweb.html()
}

['/:user/:repo/issues/new']
pub fn (mut app App) new_issue(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	if !sess.logged_in {
		return c.not_found()
	}
	sess.show_menu = true
	return $vweb.html()
}

[post]
['/:user/:repo/issues/new']
pub fn (mut app App) add_issue(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	if !sess.logged_in || (sess.logged_in && sess.user.nr_posts >= posts_per_day) {
		return app.r_home(mut c)
	}
	title := c.form['title'] // TODO use fn args
	text := c.form['text']
	if title == '' || text == '' {
		return c.redirect('/$user/$repo/new_issue')
	}
	issue := Issue{
		title: title
		text: text
		repo_id: sess.repo.id
		author_id: sess.user.id
		created_at: int(time.now().unix)
	}
	app.inc_user_post(mut sess.user)
	app.insert_issue(issue)
	app.inc_repo_issues(mut c, sess.repo.id)
	return c.redirect('/$user/$repo/issues')
}

[post]
['/:user/:repo/comment']
pub fn (mut app App) add_comment(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.not_found()
	}
	text := c.form['text']
	issue_id := c.form['issue_id']
	if text == '' || issue_id == '' || !sess.logged_in {
		return c.redirect('/$user/$repo/issue/$issue_id')
	}
	comm := Comment{
		author_id: sess.user.id
		issue_id: issue_id.int()
		created_at: int(time.now().unix)
		text: text
	}
	app.insert_comment(comm)
	app.inc_issue_comments(comm.issue_id)
	return c.redirect('/$user/$repo/issue/$issue_id')
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
