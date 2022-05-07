module main

import crypto.sha256
import time
import os

pub fn (mut app App) set_user_block_status(user_id int, status bool) {
	sql app.db {
		update User set is_blocked = status where id == user_id
	}
}

pub fn (mut app App) set_user_admin_status(user_id int, status bool) {
	sql app.db {
		update User set is_admin = status where id == user_id
	}
}

fn hash_password_with_salt(password string, salt string) string {
	set_rand_crypto_safe_seed()

	salted_password := '$password$salt'

	return sha256.sum(salted_password.bytes()).hex().str()
}

fn compare_password_with_hash(password string, salt string, hashed string) bool {
	return hash_password_with_salt(password, salt) == hashed
}

pub fn (mut app App) register_user(username string, password string, salt string, emails []string, github bool, is_admin bool) bool {
	mut user := app.find_user_by_username(username) or { User{} }

	if user.id != 0 && user.is_registered {
		app.info('User $username already exists')
		return false
	}

	user = app.find_user_by_email(emails[0]) or { User{} }

	if user.id == 0 {
		user = User{
			username: username
			password: password
			salt: salt
			is_registered: true
			is_github: github
			github_username: username
			is_admin: is_admin
		}

		app.add_user(user)

		mut u := app.find_user_by_username(user.username) or {
			app.info('User was not inserted')
			return false
		}

		if u.password != user.password || u.username != user.username {
			app.info('User was not inserted')
			return false
		}

		for email in emails {
			app.add_email(u.id, email)
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
			}
			return true
		}
	}
	app.create_user_dir(username)

	return true
}

fn (mut app App) create_user_dir(username string) {
	user_path := '$app.settings.repo_storage_path/$username'

	os.mkdir(user_path) or {
		app.info('Failed to create $user_path')
		app.info('Error: $err')
		return
	}
}

pub fn (mut app App) update_user_avatar(data string, id int) {
	sql app.db {
		update User set avatar = data where id == id
	}
}

pub fn (mut app App) create_empty_user(username string, email string) int {
	us := app.find_user_by_username(username) or { User{} }

	if us.username != '' {
		return us.id
	}

	mut user := User{
		username: username
		is_registered: false
	}

	app.add_user(user)

	u := app.find_user_by_username(user.username) or {
		app.info('User was not inserted')
		return -1
	}

	if user.username != u.username {
		app.info('User was not inserted')
		return -1
	}

	app.add_email(u.id, email)

	return u.id
}

pub fn (mut app App) add_user(user User) {
	sql app.db {
		insert user into User
	}
}

pub fn (mut app App) add_email(user_id int, email string) {
	user_email := Email{
		user_id: user_id
		email: email
	}

	sql app.db {
		insert user_email into Email
	}
}

pub fn (mut app App) add_contributor(user_id int, repo_id int) {
	if !app.contains_contributor(user_id, repo_id) {
		contributor := Contributor{
			user_id: user_id
			repo_id: repo_id
		}

		sql app.db {
			insert contributor into Contributor
		}
	}
}

pub fn (mut app App) find_username_by_id(id int) string {
	user := sql app.db {
		select from User where id == id limit 1
	}

	return user.username
}

pub fn (mut app App) find_user_by_username(username string) ?User {
	users := sql app.db {
		select from User where username == username
	}

	if users.len == 0 {
		return error('User not found')
	}

	mut u := users[0]

	emails := app.find_user_emails(u.id)
	u.emails = emails

	return u
}

pub fn (mut app App) find_user_by_id(id2 int) ?User {
	mut user := sql app.db {
		select from User where id == id2
	}

	if user.id == 0 {
		return none
	}

	emails := app.find_user_emails(user.id)
	user.emails = emails

	return user
}

pub fn (mut app App) find_user_by_github_username(name string) ?User {
	mut user := sql app.db {
		select from User where github_username == name limit 1
	}

	if user.id == 0 {
		return none
	}

	emails := app.find_user_emails(user.id)
	user.emails = emails

	return user
}

pub fn (mut app App) find_user_by_email(email string) ?User {
	emails := sql app.db {
		select from Email where email == email
	}

	if emails.len != 1 {
		return error('Email do not exist')
	}

	return app.find_user_by_id(emails[0].user_id)
}

pub fn (mut app App) find_user_emails(user_id int) []Email {
	emails := sql app.db {
		select from Email where user_id == user_id
	}

	return emails
}

pub fn (mut app App) find_repo_registered_contributor(id int) []User {
	contributors := sql app.db {
		select from Contributor where repo_id == id
	}

	mut users := []User{cap: contributors.len}

	for contributor in contributors {
		user := app.find_user_by_id(contributor.user_id) or { continue }

		users << user
	}

	return users
}

pub fn (mut app App) get_all_registered_users() []User {
	mut users := sql app.db {
		select from User where is_registered == true
	}

	for i, user in users {
		users[i].b_avatar = user.avatar != ''

		if !users[i].b_avatar {
			users[i].avatar = user.username[..1]
		}

		users[i].emails = app.find_user_emails(user.id)
	}

	return users
}

pub fn (mut app App) get_users_count() int {
	return sql app.db {
		select count from User
	}
}

pub fn (mut app App) get_count_repo_contributors(id int) int {
	return sql app.db {
		select count from Contributor where repo_id == id
	}
}

pub fn (mut app App) contains_contributor(user_id int, repo_id int) bool {
	contributors := sql app.db {
		select from Contributor where repo_id == repo_id && user_id == user_id
	}

	return contributors.len > 0
}

pub fn (mut app App) increment_user_post(mut user User) {
	user.posts_count++

	u := *user
	id := u.id
	now := int(time.now().unix)
	lastplus := int(time.unix(u.last_post_time).add_days(1).unix)

	if now >= lastplus {
		user.last_post_time = now
		sql app.db {
			update User set posts_count = 0, last_post_time = now where id == id
		}
	}

	sql app.db {
		update User set posts_count = posts_count + 1 where id == id
	}
}

pub fn (mut app App) increment_user_login_attempts(user_id int) {
	sql app.db {
		update User set login_attempts = login_attempts + 1 where id == user_id
	}
}

pub fn (mut app App) update_user_login_attempts(user_id int, attempts int) {
	sql app.db {
		update User set login_attempts = attempts where id == user_id
	}
}

pub fn (mut app App) check_user_blocked(user_id int) bool {
	user := app.find_user_by_id(user_id) or { return false }

	return user.is_blocked
}

fn (mut app App) change_username(user_id int, username string) {
	sql app.db {
		update User set username = username where id == user_id
	}

	sql app.db {
		update Repo set user_name = username where user_id == user_id
	}
}

fn (mut app App) incement_namechanges(user_id int) {
	now := int(time.now().unix)

	sql app.db {
		update User set namechanges_count = namechanges_count + 1, last_namechange_time = now
		where id == user_id
	}
}

fn (mut app App) check_username(username string) (bool, User) {
	if username.len == 0 {
		return false, User{}
	}

	mut user := app.find_user_by_username(username) or { return false, User{} }

	user.b_avatar = user.avatar != ''

	if !user.b_avatar {
		user.avatar = user.username[..1]
	}

	return user.is_registered, user
}

pub fn (mut app App) auth_user(user User, ip string) {
	token := app.add_token(user.id, ip)

	app.update_user_login_attempts(user.id, 0)

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

	mut user := app.find_user_by_id(token.user_id) or { return none }

	user.b_avatar = user.avatar != ''

	if !user.b_avatar {
		user.avatar = user.username[..1]
	}

	return user
}
