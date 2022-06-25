// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import time
import os
import log
import sqlite

const (
	commits_per_page   = 35
	http_port          = 8080
	expire_length      = 200
	posts_per_day      = 5
	max_username_len   = 40
	max_login_attempts = 5
	max_user_repos     = 10
	max_repo_name_len  = 100
	max_namechanges    = 3
	namechange_period  = time.hour * 24
)

struct App {
	vweb.Context
	started_at i64 [vweb_global]
pub mut:
	db sqlite.DB
mut:
	version       string        [vweb_global]
	logger        log.Log       [vweb_global]
	settings      GitlySettings
	current_path  string
	repo          Repo
	html_path     vweb.RawHtml
	page_gen_time string
	is_tree       bool
	show_menu     bool
	logged_in     bool
	user          User
	path_split    []string
	branch        string
}

fn C.sqlite3_config(int)

fn main() {
	C.sqlite3_config(3)

	if os.args.contains('ci_run') {
		return
	}

	vweb.run(new_app(), http_port)
}

fn new_app() &App {
	mut app := &App{
		db: sqlite.connect('gitly.sqlite') or { panic(err) }
		started_at: time.now().unix
	}

	set_rand_crypto_safe_seed()

	app.create_tables()

	create_directory_if_not_exists('logs')

	app.setup_logger()

	mut version := os.read_file('static/assets/version') or { 'unknown' }
	git_result := os.execute('git rev-parse --short HEAD')

	if git_result.exit_code == 0 && !git_result.output.contains('fatal') {
		version = git_result.output.trim_space()
	}

	if version != app.version {
		os.write_file('static/assets/version', app.version) or { panic(err) }
	}

	app.version = version

	app.handle_static('static', true)

	app.load_settings()

	create_directory_if_not_exists(app.settings.repo_storage_path)
	create_directory_if_not_exists(app.settings.archive_path)

	// Create the first admin user if the db is empty
	app.find_user_by_id(1) or {}

	if '-cmdapi' in os.args {
		go app.command_fetcher()
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

pub fn (mut app App) before_request() {
	app.logged_in = app.is_logged_in()

	app.load_settings()

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

	app.add_visit(app.repo.id, app.req.url, app.req.referer())
}

['/']
pub fn (mut app App) index() vweb.Result {
	app.show_menu = false

	no_users := app.get_users_count() == 0
	if no_users {
		return app.redirect('/register')
	}

	return $vweb.html()
}

pub fn (mut app App) redirect_to_index() vweb.Result {
	return app.redirect('/')
}

pub fn (mut app App) redirect_to_login() vweb.Result {
	return app.redirect('/login')
}

pub fn (mut app App) redirect_to_current_repository() vweb.Result {
	return app.redirect('/$app.user.username/$app.repo.name')
}

fn (mut app App) create_tables() {
	sql app.db {
		create table Repo
	}
	// unix time default now
	sql app.db {
		create table File
	} // missing ON CONFLIC REPLACE
	//"created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Issue
	}
	//"created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Commit
	}
	// author text default '' is to to avoid joins
	sql app.db {
		create table LangStat
	}
	sql app.db {
		create table User
	}
	sql app.db {
		create table Email
	}
	sql app.db {
		create table Contributor
	}
	sql app.db {
		create table Tag
	}
	sql app.db {
		create table Release
	}
	sql app.db {
		create table SshKey
	}
	sql app.db {
		create table Comment
	}
	sql app.db {
		create table Branch
	}
	sql app.db {
		create table Visit
	}
	sql app.db {
		create table GitlySettings
	}
	sql app.db {
		create table Token
	}
	sql app.db {
		create table SecurityLog
	}
}

// maybe it should be implemented with another static server, in dev
fn (mut app App) send_file(filname string, content string) vweb.Result {
	app.add_header('Content-Disposition', 'attachment; filename="$filname"')

	return app.ok(content)
}
