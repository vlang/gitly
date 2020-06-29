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
	commits_per_page = 35
	http_port        = 8080
)

struct App {
mut:
	reponame      string
	subdomain     string
	path          string // current path being viewed
	branch        string
	repo          Repo
	version       string
	html_path     vweb.RawHtml
	page_gen_time string
pub mut:
	tokens        map[string]string // [userid] = token
	file_log      log.Log
	cli_log       log.Log
	vweb          vweb.Context
	db            sqlite.DB
	logged_in     bool
	user          User
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
	app.tokens = map[string]string
	app.file_log = log.Log{}
	app.cli_log = log.Log{}
	app.file_log.set_level(.info)
	app.cli_log.set_level(.info)
	date := time.now()
	date_s := '${date.ymmdd()}'
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
	mut user := User{
		name: 'Admin'
		username: 'admin'
		password: make_password('test', 'admin')
		is_github: false
	}
	email := Email{
		user: 1
		email: 'admin@mail.com'
	}
	app.reponame = ''
	app.subdomain = ''
	app.path = ''
	app.branch = ''
	app.vweb.serve_static('/gitly.css', 'static/css/gitly.css', 'text/css')
	app.vweb.serve_static('/jquery.js', 'static/js/jquery.js', 'text/javascript')
	app.vweb.serve_static('/favicon.svg', 'static/assets/favicon.svg', 'image/svg+xml')
	app.db = sqlite.connect('gitly.sqlite') or {
		panic(err)
	}
	app.create_tables()
	app.insert_user(user)
	app.insert_email(email)
	go app.create_new_test_repo() // if it doesn't exist
	if '-cmdapi' in os.args {
		go app.command_fetcher()
	}
}

pub fn (mut app App) command_fetcher() {
	for {
		line := os.get_line()
		if line.starts_with('!') {
			args := line[1..].split(' ')
			if args.len > 0 {
				match args[0] {
					'updaterepo' {
						app.update_repo()
					}
					'adduser' {
						if args.len > 4 {
							app.add_user(args[1], args[2], args[3], args[4..])
							println('Added user ${args[1]}')
						} else {
							error('Not enough arguments (4 required but only $args.len given)')
						}
					}
					else {
						println('Commands:')
						println('	!updaterepo')
						println('	!adduser <username> <gitname> <password> <email1> <email2>...')
					}
				}
			} else {
				error('Unkown syntax. Use !<command>')
			}
		} else {
			error('Unkown syntax. Use !<command>')
		}
	}
}

pub fn (mut app App) init() {
	url := app.vweb.req.url
	app.page_gen_time = ''
	app.info('\n\ninit() url=$url')
	app.reponame = 'v'
	app.subdomain = 'vlang'
	if url.contains('/tree/') {
		app.path = url.after('/tree/')
	} else if url.contains('/blob/') {
		app.path = url.after('/blob/')
	} else if url.contains('/commits/') {
		app.path = url.after('/commits/')
	} else if url.contains('/commit/') {
		app.path = url.after('/commit/')
	} else if url.contains('/issue/') {
		app.path = url.after('/issue/')
	} else if url.contains('/user/') {
		app.path = url.after('/user/')
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
		app.user = app.get_user() or {
			app.logged_in = false
			User{}
		}
	}
}

pub fn (mut app App) create_new_test_repo() {
	if x := app.find_repo_by_name('v') {
		app.info('test repo already exists')
		app.repo = x
		app.repo.lang_stats = app.find_lang_stats_by_repo_id(app.repo.id)
		// init branches list for existing repo
		mut r := &app.repo
		r.branches = get_branches(r)
		return
	}
	_ := os.ls('.') or {
		return
	}
	cur_dir := os.base_dir(os.executable())
	git_dir := os.join_path(cur_dir, 'test_repo')
	if !os.exists(git_dir) {
		app.warn('Right now Gitly can only work with a single repo.')
		app.warn('Create a test repo in a directory `test_repo` next to the Gitly executable. For example:')
		app.warn('git clone https://github.com/vlang/v test_repo')
		exit(1)
	}
	app.repo = Repo{
		name: 'v'
		git_dir: git_dir
		lang_stats: test_lang_stats
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

// pub fn (mut app App) tree(path string) {
pub fn (mut app App) tree() vweb.Result {
	if app.path.contains('/favicon.svg') {
		return vweb.not_found()
	}
	// t := time.ticks()
	mut up := ''
	mut poss_up := true
	args := app.path.split('/')
	app.inc_repo_views(app.repo.id)
	if args.len == 0 {
		poss_up = false
	}
	if args.len > 1 {
		up_a := args[0..args.len - 1]
		up += '/tree/'
		up += up_a.join('/')
	} else {
		up = '/'
	}
	app.info('up: $up')
	if app.path.starts_with('/') {
		app.path = app.path[1..]
	}
	mut files := app.find_files_by_repo(app.repo.id, 'master', app.path)
	app.info('tree() nr files found: $files.len')
	if files.len == 0 {
		// No files in the db, fetch them from git and cache in db
		app.info('caching files, repo_id=$app.repo.id')
		// t := time.ticks()
		files = app.cache_repo_files(mut app.repo, 'master', app.path)
		// println('caching files took ${time.ticks()-t}ms')
		go app.slow_fetch_files_info('master', app.path)
	}

	mut last_commit := Commit{}
	if poss_up {
		mut path := app.path
		if path.ends_with('/') {
			path = path[0..path.len-1]
		}
		if !path.contains('/') {
			path = '/$path'
		}
		println(path)
		upper_dir := app.find_file_by_path(app.repo.id, 'master', '$path') or { panic(err) }
		last_commit = app.find_commit_by_hash(app.repo.id, upper_dir.last_hash)
	} else {
		last_commit = app.find_last_commit(app.repo.id)
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
	app.tree()
	return $vweb.html()
}

pub fn (mut app App) user() vweb.Result {
	args := app.path.split('/')
	mut user := User{}
	if args.len >= 1 {
		username := args[0]
		user = app.find_user_by_username(username) or {
			return app.vweb.not_found()
		}
	}
	return $vweb.html()
}

pub fn (mut app App) commits() vweb.Result {
	args := app.path.split('/')
	page := if args.len >= 1 { args.last().int() } else { 0 }
	mut commits := app.find_commits_by_repo_as_page(app.repo.id, page)
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
	mut url := ''
	if args.len > 0 {
		url = args[..args.len - 1].join('/')
		if url != '' {
			url += '/'
		}
	}
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
	app.path = ''
	return $vweb.html()
}

pub fn (mut app App) commit() vweb.Result {
	hash := app.path.split('/')[0]
	commit := app.find_commit_by_hash(app.repo.id, hash)
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

pub fn (mut app App) issues() vweb.Result {
	mut issues := app.find_issues_by_repo(app.repo.id)
	for index, issue in issues {
		issues[index].author_name = app.find_username_by_id(issue.author_id)
	}
	return $vweb.html()
}

pub fn (mut app App) issue() vweb.Result {
	args := app.path.split('/')
	app.path = ''
	mut id := 1
	if args.len > 0 {
		id = args[0].int()
	}
	issue0 := app.find_issue_by_id(id) or {
		return app.vweb.not_found()
	}
	mut issue := issue0 // TODO bug with optionals (.data)
	issue.author_name = app.find_username_by_id(issue.author_id)
	comments := app.find_issue_comments(issue.id)
	return $vweb.html()
}

pub fn (mut app App) pull() vweb.Result {
	_ := app.path.split('/')
	id := 0
	pr0 := app.find_pr_by_id(id) or {
		panic(err)
		// return app.vweb.not_found()
	}
	pr := pr0
	comments := app.find_issue_comments(pr.id)
	return $vweb.html()
}

pub fn (mut app App) pulls() vweb.Result {
	prs := app.find_prs_by_repo(app.repo.id)
	return $vweb.html()
}

pub fn (mut app App) contributors() vweb.Result {
	users := app.find_registered_contributor_by_repo_id(app.repo.id)
	named_contributor := app.find_named_contributor_by_repo_id(app.repo.id)
	return $vweb.html()
}

pub fn (mut app App) branches() vweb.Result {
	branches := app.repo.branches
	return $vweb.html()
}

pub fn (mut app App) releases() vweb.Result {
	mut releases := []Release{}
	mut release := Release{}
	tags := app.find_tags_by_repo_id(app.repo.id)
	rels := app.find_releases_by_repo_id(app.repo.id)
	users := app.find_registered_contributor_by_repo_id(app.repo.id)
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
	releases.sort_with_compare(compare_reldate)
	return $vweb.html()
}

fn compare_reldate(a, b &Release) int {
	if a.date.gt(b.date) {
		return -1
	}
	if a.date.lt(b.date) {
		return 1
	}
	return 0
}

pub fn (mut app App) blob() vweb.Result {
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

pub fn (mut app App) new_issue() vweb.Result {
	if !app.logged_in {
		return app.vweb.not_found()
	}
	return $vweb.html()
}

pub fn (mut app App) new_issue_post() vweb.Result {
	title := app.vweb.form['title'] // TODO use fn args
	text := app.vweb.form['text']
	if title == '' || text == '' {
		app.vweb.redirect('/new_issue')
		return vweb.Result{}
	}
	issue := Issue{
		title: title
		text: text
		repo_id: app.repo.id
		author_id: app.user.id
	}
	app.insert_issue(issue)
	app.inc_repo_issues(app.repo.id)
	app.vweb.redirect('/issues')
	return vweb.Result{}
}

pub fn (mut app App) register() vweb.Result {
	return $vweb.html()
}

pub fn (mut app App) register_post() vweb.Result {
	username := app.vweb.form['username']
	git_name := app.vweb.form['gitname']
	password := make_password(app.vweb.form['password'], username)
	email := app.vweb.form['email']
	if username == '' || git_name == '' || email == '' {
		app.vweb.redirect('/register')
		return vweb.Result{}
	}
	app.add_user(username, password, git_name, [email])
	app.vweb.redirect('/')
	return vweb.Result{}
}

pub fn (mut app App) login() vweb.Result {
	if app.logged_in() {
		return app.vweb.not_found()
	}
	return $vweb.html()
}

pub fn (mut app App) login_post() vweb.Result {
	username := app.vweb.form['username']
	password := app.vweb.form['password']

	if username == '' || password == '' {
		app.vweb.redirect('/login')
		return vweb.Result{}
	}
	user := app.find_user_by_username(username) or {
		app.vweb.redirect('/login')
		return vweb.Result{}
	}
	if !check_password(password, username, user.password) {
		app.vweb.redirect('/login')
		return vweb.Result{}
	}
	token := app.add_token(user.id)
	app.vweb.set_cookie('id', user.id.str())
	app.vweb.set_cookie('token', token)
	app.vweb.redirect('/')
	return vweb.Result{}
}

pub fn (mut app App) logged_in() bool {
	id := app.vweb.get_cookie('id') or {
		return false
	}
	token := app.vweb.get_cookie('token') or {
		return false
	}
	return id != '' && token != '' && id in app.tokens && app.tokens[id] == token
}

fn gen_uuid_v4ish() string {
    // UUIDv4 format: 4-2-2-2-6 bytes per section
    a := rand.intn(math.max_i32 / 2).hex()
    b := rand.intn(math.max_i16).hex()
    c := rand.intn(math.max_i16).hex()
    d := rand.intn(math.max_i16).hex()
    e := rand.intn(math.max_i32 / 2).hex()
    f := rand.intn(math.max_i16).hex()
    return '${a:08}-${b:04}-${c:04}-${d:04}-${e:08}${f:04}'.replace(' ','0')
}

pub fn (mut app App) add_token(user_id int) string {
	token := gen_uuid_v4ish()
	app.tokens[user_id.str()] = token
	return token
}

pub fn (mut app App) get_user() ?User {
	id := app.vweb.get_cookie('id') or { return error('Not logged in') }
	return app.find_user_by_id(id.int())
}
