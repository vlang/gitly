// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import time
import os
import log
import db.sqlite
import api
import config

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
	db sqlite.DB
mut:
	version  string
	logger   log.Log
	config   config.Config
	settings Settings
}

pub struct Context {
	veb.Context
mut:
	user          User
	current_path  string
	page_gen_time string
	is_tree       bool
	logged_in     bool
	path_split    []string
	branch        string
}

fn C.sqlite3_config(int)

fn new_app() !&App {
	C.sqlite3_config(3)

	mut app := &App{
		db:         sqlite.connect('gitly.sqlite') or { panic(err) }
		started_at: time.now().unix()
	}

	set_rand_crypto_safe_seed()

	app.create_tables()!

	create_directory_if_not_exists('logs')

	app.setup_logger()

	mut version := os.read_file('src/static/assets/version') or { 'unknown' }
	git_result := os.execute('git rev-parse --short HEAD')

	if git_result.exit_code == 0 && !git_result.output.contains('fatal') {
		version = git_result.output.trim_space()
	}

	if version != app.version {
		os.write_file('src/static/assets/version', app.version) or { panic(err) }
	}

	app.version = version

	app.handle_static('src/static', true)!
	if !os.exists('avatars') {
		os.mkdir('avatars')!
	}
	app.handle_static('avatars', false)!

	app.load_settings()

	app.config = config.read_config('./config.json') or {
		panic('Config not found or has syntax errors')
	}

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

pub fn (mut app App) before_request(mut ctx Context) {
	ctx.logged_in = app.is_logged_in(mut ctx)

	app.load_settings()

	if ctx.logged_in {
		ctx.user = app.get_user_from_cookies(ctx) or {
			ctx.logged_in = false
			User{}
		}
	}
}

@['/']
pub fn (mut app App) index() veb.Result {
	user_count := app.get_users_count() or { 0 }
	no_users := user_count == 0
	if no_users {
		return ctx.redirect('/register')
	}

	return $veb.html()
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
	//"created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Commit
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
