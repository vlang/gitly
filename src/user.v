module main

import crypto.sha256
import time
import os

struct User {
	id              int       @[primary; sql: serial]
	full_name       string
	username        string    @[unique]
	github_username string
	password        string
	salt            string
	created_at      time.Time
	is_github       bool
	is_registered   bool
	is_blocked      bool
	is_admin        bool
	oauth_state     string    @[skip]
mut:
	// for github oauth XSRF protection
	namechanges_count    int
	last_namechange_time int
	posts_count          int
	last_post_time       int
	avatar               string
	emails               []Email @[skip]
	login_attempts       int
}

struct Email {
	id      int    @[primary; sql: serial]
	user_id int
	email   string @[unique]
}

struct Contributor {
	id      int @[primary; sql: serial]
	user_id int @[unique: 'contributor']
	repo_id int @[unique: 'contributor']
}

pub fn (mut app App) set_user_block_status(user_id int, status bool) ! {
	sql app.db {
		update User set is_blocked = status where id == user_id
	}!
}

pub fn (mut app App) set_user_admin_status(user_id int, status bool) ! {
	sql app.db {
		update User set is_admin = status where id == user_id
	}!
}

fn hash_password_with_salt(password string, salt string) string {
	salted_password := '${password}${salt}'

	return sha256.sum(salted_password.bytes()).hex().str()
}

fn compare_password_with_hash(password string, salt string, hashed string) bool {
	return hash_password_with_salt(password, salt) == hashed
}

pub fn (mut app App) register_user(username string, password string, salt string, emails []string, github bool, is_admin bool) !bool {
	mut user := app.get_user_by_username(username) or { User{} }

	if user.id != 0 && user.is_registered {
		app.info('User ${username} already exists')
		return false
	}

	user = app.get_user_by_email(emails[0]) or { User{} }

	if user.id == 0 {
		user = User{
			username: username
			password: password
			salt: salt
			created_at: time.now()
			is_registered: true
			is_github: github
			github_username: username
			avatar: default_avatar_name
			is_admin: is_admin
		}

		app.add_user(user)!

		mut u := app.get_user_by_username(user.username) or {
			app.info('User was not inserted')
			return false
		}

		if u.password != user.password || u.username != user.username {
			app.info('User was not inserted')
			return false
		}

		app.add_activity(u.id, 'joined')!

		for email in emails {
			app.add_email(u.id, email)!
		}

		u.emails = app.find_user_emails(u.id)
	} else {
		// Update existing user
		if !github {
			app.create_user_dir(username)

			return true
		}

		if user.is_registered {
			sql app.db {
				update User set is_github = true where id == user.id
			}!
			return true
		}
	}
	app.create_user_dir(username)

	return true
}

fn (mut app App) create_user_dir(username string) {
	user_path := '${app.config.repo_storage_path}/${username}'

	os.mkdir(user_path) or {
		app.info('Failed to create ${user_path}')
		app.info('Error: ${err}')
		return
	}
}

pub fn (mut app App) update_user_avatar(user_id int, filename_or_url string) ! {
	sql app.db {
		update User set avatar = filename_or_url where id == user_id
	}!
}

pub fn (mut app App) add_user(user User) ! {
	sql app.db {
		insert user into User
	}!
}

pub fn (mut app App) add_email(user_id int, email string) ! {
	user_email := Email{
		user_id: user_id
		email: email
	}

	sql app.db {
		insert user_email into Email
	}!
}

pub fn (mut app App) add_contributor(user_id int, repo_id int) ! {
	if !app.contains_contributor(user_id, repo_id) {
		contributor := Contributor{
			user_id: user_id
			repo_id: repo_id
		}

		sql app.db {
			insert contributor into Contributor
		}!
	}
}

pub fn (app App) get_username_by_id(id int) ?string {
	users := sql app.db {
		select from User where id == id limit 1
	} or { [] }

	if users.len == 0 {
		return none
	}

	return users.first().username
}

pub fn (app App) get_user_by_username(value string) ?User {
	users := sql app.db {
		select from User where username == value limit 1
	} or { [] }

	if users.len == 0 {
		return none
	}

	mut user := users.first()
	emails := app.find_user_emails(user.id)
	user.emails = emails

	return user
}

pub fn (app App) get_user_by_id(id int) ?User {
	users := sql app.db {
		select from User where id == id
	} or { [] }

	if users.len == 0 {
		return none
	}

	mut user := users.first()
	emails := app.find_user_emails(user.id)
	user.emails = emails

	return user
}

pub fn (mut app App) get_user_by_github_username(name string) ?User {
	users := sql app.db {
		select from User where github_username == name limit 1
	} or { [] }

	if users.len == 0 {
		return none
	}

	mut user := users.first()
	emails := app.find_user_emails(user.id)
	user.emails = emails

	return user
}

pub fn (mut app App) get_user_by_email(value string) ?User {
	emails := sql app.db {
		select from Email where email == value
	} or { [] }

	if emails.len != 1 {
		return none
	}

	return app.get_user_by_id(emails[0].user_id)
}

pub fn (app App) find_user_emails(user_id int) []Email {
	emails := sql app.db {
		select from Email where user_id == user_id
	} or { [] }

	return emails
}

pub fn (mut app App) find_repo_registered_contributor(id int) []User {
	contributors := sql app.db {
		select from Contributor where repo_id == id
	} or { [] }

	mut users := []User{cap: contributors.len}

	for contributor in contributors {
		user := app.get_user_by_id(contributor.user_id) or { continue }

		users << user
	}

	return users
}

pub fn (mut app App) get_all_registered_users_as_page(offset int) []User {
	// FIXME: 30 -> admin_users_per_page
	mut users := sql app.db {
		select from User where is_registered == true limit 30 offset offset
	} or { [] }

	for i, user in users {
		users[i].emails = app.find_user_emails(user.id)
	}

	return users
}

pub fn (mut app App) get_all_registered_user_count() int {
	return sql app.db {
		select count from User where is_registered == true
	} or { 0 }
}

fn (app App) search_users(query string) []User {
	q := 'select id, full_name, username, avatar from `User` where is_blocked is false and ' +
		'(username like "%${query}%" or full_name like "%${query}%")'
	repo_rows := app.db.exec(q) or { return [] }
	mut users := []User{}
	for row in repo_rows {
		users << User{
			id: row.vals[0].int()
			full_name: row.vals[1]
			username: row.vals[2]
			avatar: row.vals[3]
		}
	}
	return users
}

pub fn (mut app App) get_users_count() !int {
	return sql app.db {
		select count from User
	} or { 0 }
}

pub fn (mut app App) get_count_repo_contributors(id int) !int {
	return sql app.db {
		select count from Contributor where repo_id == id
	} or { 0 }
}

pub fn (mut app App) contains_contributor(user_id int, repo_id int) bool {
	contributors := sql app.db {
		select from Contributor where repo_id == repo_id && user_id == user_id
	} or { [] }

	return contributors.len > 0
}

pub fn (mut app App) increment_user_post(mut user User) ! {
	user.posts_count++

	u := *user
	id := u.id
	now := int(time.now().unix())
	lastplus := int(time.unix(u.last_post_time).add_days(1).unix())

	if now >= lastplus {
		user.last_post_time = now
		sql app.db {
			update User set posts_count = 0, last_post_time = now where id == id
		}!
	}

	sql app.db {
		update User set posts_count = posts_count + 1 where id == id
	}!
}

pub fn (mut app App) increment_user_login_attempts(user_id int) ! {
	sql app.db {
		update User set login_attempts = login_attempts + 1 where id == user_id
	}!
}

pub fn (mut app App) update_user_login_attempts(user_id int, attempts int) ! {
	sql app.db {
		update User set login_attempts = attempts where id == user_id
	}!
}

pub fn (mut app App) check_user_blocked(user_id int) bool {
	user := app.get_user_by_id(user_id) or { return false }

	return user.is_blocked
}

fn (mut app App) change_username(user_id int, username string) ! {
	sql app.db {
		update User set username = username where id == user_id
	}!

	sql app.db {
		update Repo set user_name = username where user_id == user_id
	}!
}

fn (mut app App) change_full_name(user_id int, full_name string) ! {
	sql app.db {
		update User set full_name = full_name where id == user_id
	}!
}

fn (mut app App) incement_namechanges(user_id int) ! {
	now := int(time.now().unix())

	sql app.db {
		update User set namechanges_count = namechanges_count + 1, last_namechange_time = now
		where id == user_id
	}!
}

fn (mut app App) check_username(username string) (bool, User) {
	if username.len == 0 {
		return false, User{}
	}

	mut user := app.get_user_by_username(username) or { return false, User{} }

	return user.is_registered, user
}

pub fn (mut app App) auth_user(user User, ip string) ! {
	token := app.add_token(user.id, ip)!

	app.update_user_login_attempts(user.id, 0)!

	expire_date := time.now().add_days(200)

	app.set_cookie(name: 'token', value: token, expires: expire_date)
}

pub fn (mut app App) is_logged_in() bool {
	token_cookie := app.get_cookie('token') or { return false }

	token := app.get_token(token_cookie) or { return false }

	is_user_blocked := app.check_user_blocked(token.user_id)

	if is_user_blocked {
		app.handle_logout()

		return false
	}

	return true
}

pub fn (mut app App) get_user_from_cookies() ?User {
	token_cookie := app.get_cookie('token') or { return none }

	token := app.get_token(token_cookie) or { return none }

	mut user := app.get_user_by_id(token.user_id) or { return none }

	return user
}
