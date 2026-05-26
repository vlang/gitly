// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import time
import os
import log
import api
import config
import git

const commits_per_page = 35
const expire_length = 200
const posts_per_day = 5
const max_username_len = 40
const max_login_attempts = 5
const max_user_repos = 10
const max_repo_name_len = 100
const max_namechanges = 3
const namechange_period = time.hour * 24

@[heap]
pub struct App {
	veb.StaticHandler
	veb.Middleware[Context]
	started_at i64
pub mut:
	db GitlyDb
mut:
	version    string
	build_time string
	logger     log.Log
	config     config.Config
	settings   Settings
	port       int
}

pub struct Context {
	veb.Context
mut:
	user           User
	current_path   string
	page_gen_time  string
	page_gen_start i64
	is_tree        bool
	logged_in      bool
	path_split     []string
	branch         string
	lang           Lang = .en //.ru
}

// fn C.sqlite3_config(int)

fn new_app() !&App {
	// C.sqlite3_config(3)
	conf := config.read_config('./config.json') or {
		panic('Config not found or has syntax errors')
	}

	mut app := &App{
		// db: sqlite.connect('gitly.sqlite') or { panic(err) }
		db:         connect_db(conf)!
		config:     conf
		started_at: time.now().unix()
	}

	set_rand_crypto_safe_seed()

	app.create_tables()!
	app.migrate_tables()!

	create_directory_if_not_exists('logs')

	app.setup_logger()

	version_path := os.join_path('static', 'assets', 'version')
	create_directory_if_not_exists(os.dir(version_path))

	stored_version := os.read_file(version_path) or { 'unknown' }
	mut version := stored_version
	git_result := git.Git.exec(['rev-parse', '--short', 'HEAD'])

	if git_result.exit_code == 0 && !git_result.output.contains('fatal') {
		version = git_result.output.trim_space()
	}

	if version != stored_version {
		os.write_file(version_path, version) or { panic(err) }
	}

	app.version = version

	build_unix := os.file_last_mod_unix(os.executable())
	app.build_time = time.unix(build_unix).format()

	app.handle_static('static', true)!
	app.serve_static('/favicon.ico', 'static/assets/favicon.svg')!
	if !os.exists('avatars') {
		os.mkdir('avatars')!
	}
	app.handle_static('avatars', false)!

	app.load_settings()

	create_directory_if_not_exists(app.config.repo_storage_path)
	create_directory_if_not_exists(app.config.archive_path)
	create_directory_if_not_exists(app.config.avatars_path)

	// Create the first admin user if the db is empty
	app.get_user_by_id(1) or {}

	if '-cmdapi' in os.args {
		spawn app.command_fetcher()
	}

	return app
}

fn (mut app App) setup_logger() {
	app.logger.set_level(.debug)

	app.logger.set_full_logpath('./logs/log_${time.now().ymmdd()}.log')
	app.logger.log_to_console_too()
}

pub fn (mut app App) warn(msg string) {
	app.logger.warn(msg)

	app.logger.flush()
}

pub fn (mut app App) info(msg string) {
	app.logger.info(msg)

	app.logger.flush()
}

pub fn (mut app App) debug(msg string) {
	app.logger.debug(msg)

	app.logger.flush()
}

pub fn (mut app App) init_server() {
}

pub fn (mut app App) before_request(mut ctx Context) bool {
	ctx.page_gen_start = time.ticks()
	$if trace_prealloc ? {
		unsafe { prealloc_scope_checkpoint(c'gitly before_request start') }
	}
	ctx.logged_in = app.is_logged_in(mut ctx)
	$if trace_prealloc ? {
		unsafe { prealloc_scope_checkpoint(c'gitly checked login') }
	}
	if ctx.logged_in {
		ctx.user = app.get_user_from_cookies(ctx) or {
			ctx.logged_in = false
			User{}
		}
	}
	$if trace_prealloc ? {
		unsafe { prealloc_scope_checkpoint(c'gitly loaded user') }
	}
	lang_cookie := ctx.get_cookie('lang') or { '' }
	ctx.lang = match lang_cookie {
		'ru' { Lang.ru }
		'es' { Lang.es }
		'jp' { Lang.jp }
		'cn' { Lang.cn }
		'pt' { Lang.pt }
		else { Lang.en }
	}

	$if trace_prealloc ? {
		unsafe { prealloc_scope_checkpoint(c'gitly loaded lang') }
	}
	return true
}

@['/open-source']
pub fn (mut app App) open_source() veb.Result {
	return $veb.html()
}

@['/']
pub fn (mut app App) index(mut ctx Context) veb.Result {
	user_count := app.get_users_count_with_reconnect() or { return ctx.db_error(err) }
	if user_count == 0 {
		return ctx.redirect('/register')
	}

	return $veb.html()
}

@['/change_lang/:lang'; post]
pub fn (mut app App) change_lang(lang string) veb.Result {
	eprintln('CHANGING LANG ${lang}')
	expire_date := time.now().add_days(400)
	ctx.set_cookie(name: 'lang', value: lang, path: '/', expires: expire_date)
	// return ctx.redirect('/')
	return ctx.json('ok')
}

pub fn (mut ctx Context) redirect_to_index() veb.Result {
	return ctx.redirect('/')
}

pub fn (mut ctx Context) redirect_to_login() veb.Result {
	return ctx.redirect('/login')
}

pub fn (mut ctx Context) redirect_to_repository(username string, repo_name string) veb.Result {
	return ctx.redirect('/${username}/${repo_name}')
}

fn (mut app App) create_tables() ! {
	sql app.db {
		create table Repo
	}!
	// unix time default now
	sql app.db {
		create table File
	}! // missing ON CONFLIC REPLACE
	//"created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Issue
	}!
	sql app.db {
		create table Label
	}!
	sql app.db {
		create table IssueLabel
	}!
	//"created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Commit
	}!
	sql app.db {
		create table BranchCommit
	}!
	// author text default '' is to to avoid joins
	sql app.db {
		create table LangStat
	}!
	sql app.db {
		create table User
	}!
	sql app.db {
		create table Email
	}!
	sql app.db {
		create table Contributor
	}!
	sql app.db {
		create table Activity
	}!
	sql app.db {
		create table Tag
	}!
	sql app.db {
		create table Release
	}!
	sql app.db {
		create table SshKey
	}!
	sql app.db {
		create table Comment
	}!
	sql app.db {
		create table Branch
	}!
	sql app.db {
		create table Settings
	}!
	sql app.db {
		create table Token
	}!
	sql app.db {
		create table SecurityLog
	}!
	sql app.db {
		create table Star
	}!
	sql app.db {
		create table Watch
	}!
	sql app.db {
		create table CiStatus
	}!
	sql app.db {
		create table PullRequest
	}!
	sql app.db {
		create table PrComment
	}!
	sql app.db {
		create table PrReview
	}!
	sql app.db {
		create table PrReviewComment
	}!
	sql app.db {
		create table Webhook
	}!
	sql app.db {
		create table WebhookDelivery
	}!
	sql app.db {
		create table Discussion
	}!
	sql app.db {
		create table DiscussionComment
	}!
	sql app.db {
		create table Project
	}!
	sql app.db {
		create table ProjectColumn
	}!
	sql app.db {
		create table ProjectCard
	}!
	sql app.db {
		create table Milestone
	}!
	sql app.db {
		create table TwoFactor
	}!
	sql app.db {
		create table ApiToken
	}!
	sql app.db {
		create table Org
	}!
	sql app.db {
		create table OrgMember
	}!
}

fn (mut app App) migrate_tables() ! {
	app.add_missing_column('File', 'is_size_calculated', db_bool_column_type())!
	app.add_missing_column('Settings', 'disable_tree_folder_size', db_bool_column_type())!
	app.add_missing_column('Repo', 'is_deleted', db_bool_column_type())!
	app.add_missing_column('Repo', 'disable_discussions', db_bool_column_type())!
	app.add_missing_column('Repo', 'disable_projects', db_bool_column_type())!
	app.add_missing_column('Repo', 'disable_milestones', db_bool_column_type())!
	app.add_missing_column('Repo', 'disable_wiki', db_bool_column_type())!
	app.add_missing_column('Repo', 'is_pinned', db_bool_column_type())!

	app.db.exec('create index if not exists idx_commit_repo_created on ${sql_table('Commit')} (repo_id, created_at desc)')!
}

fn (mut app App) add_missing_column(table_name string, column_name string, column_type string) ! {
	if db_column_exists(mut app.db, table_name, column_name)! {
		return
	}

	app.db.exec('alter table ${sql_table(table_name)} add column ${sql_table(column_name)} ${column_type}')!
}

fn (mut ctx Context) json_success[T](result T) veb.Result {
	response := api.ApiSuccessResponse[T]{
		success: true
		result:  result
	}

	return ctx.json(response)
}

fn (mut ctx Context) json_error(message string) veb.Result {
	return ctx.json(api.ApiErrorResponse{
		success: false
		message: message
	})
}

// maybe it should be implemented with another static server, in dev
fn (mut app App) send_file(filname string, content string) veb.Result {
	ctx.set_header(.content_disposition, 'attachment; filename="${filname}"')

	return ctx.ok(content)
}

fn (mut ctx Context) page_gen_time() string {
	if ctx.page_gen_start == 0 {
		return '<1ms'
	}
	diff := int(time.ticks() - ctx.page_gen_start)
	return if diff == 0 {
		'<1ms'
	} else {
		'${diff}ms'
	}
}
