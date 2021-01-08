// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import crypto.sha256
import rand
import os
import time

struct User {
	id                   int
	name                 string
	username             string
	github_username      string
	password             string
	is_github            bool
	is_registered        bool
	is_blocked           bool
	is_admin             bool
	oauth_state          string  [skip]
mut:
	// for github oauth XSRF protection
	nr_namechanges       int
	last_namechange_time int
	nr_posts             int
	last_post_time       int
	avatar               string
	b_avatar             bool    [skip]
	emails               []Email [skip]
	login_attempts       int
}

struct SshKey {
	id         int
	user       int
	title      string
	sshkey     string
	is_deleted bool
}

struct Email {
	id    int
	user  int
	email string
}

struct Contributor {
	id   int
	user int
	repo int
}

struct OAuth_Request {
	client_id     string
	client_secret string
	code          string
}

fn make_password(password string, username string) string {
	mut seed := [u32(username[0]), u32(username[1])]
	rand.seed(seed)
	salt := rand.i64().str()
	pw := '$password$salt'
	return sha256.sum(pw.bytes()).hex().str()
}

fn check_password(password string, username string, hashed string) bool {
	return make_password(password, username) == hashed
}

pub fn (mut app App) add_user(username string, password string, emails []string, github bool) bool {
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
			is_registered: true
			is_github: github
			github_username: username
		}
		app.insert_user(user)
		mut u := app.find_user_by_username(user.username) or {
			app.info('User was not inserted')
			return false
		}
		if u.password != user.password || u.name != user.name {
			app.info('User was not inserted')
			return false
		}
		for email in emails {
			mail := Email{
				user: u.id
				email: email
			}
			app.insert_email(mail)
		}
		u.emails = app.find_user_emails(u.id)
	} else {
		name := user.username
		if !github {
			sql app.db {
				update User set username = username, password = password, name = name, is_registered = true
				where id == user.id
			}
			app.create_user_dir(username)
			return true
		}
		if user.is_registered {
			sql app.db {
				update User set is_github = true where id == user.id
			}
			return true
		}
		sql app.db {
			update User set username = username, name = name, is_registered = true, is_github = true
			where id == user.id
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
	mut user := User{
		username: username
		is_registered: false
	}
	app.insert_user(user)
	u := app.find_user_by_username(user.username) or {
		app.info('User was not inserted')
		return -1
	}
	if user.username != u.username {
		app.info('User was not inserted')
		return -1
	}
	mail := Email{
		user: u.id
		email: email
	}
	app.insert_email(mail)
	return u.id
}

pub fn (mut app App) insert_user(user User) {
	// app.info('Insert user: $user.username')
	sql app.db {
		insert user into User
	}
}

pub fn (mut app App) insert_email(email Email) {
	// app.info('Inserting email: $email.email')
	sql app.db {
		insert email into Email
	}
}

pub fn (mut app App) insert_sshkey(sshkey SshKey) {
	// app.info('Inserting sshkey: $sshkey.title')
	sql app.db {
		insert sshkey into SshKey
	}
}

pub fn (mut app App) insert_contributor(contributor Contributor) {
	// app.info('Inserting contributor: $contributor.user')
	sql app.db {
		insert contributor into Contributor
	}
}

pub fn (mut app App) remove_ssh_key(title string, user_id int) {
	sql app.db {
		update SshKey set is_deleted = true where title == title && user == user_id
	}
}

pub fn (mut app App) user_set_admin(id int) {
	sql app.db {
		update User set is_admin = true where id == id
	}
}

pub fn (mut app App) user_unset_admin(id int) {
	sql app.db {
		update User set is_admin = false where id == id
	}
}

pub fn (mut app App) find_user_sshkeys(id int) []SshKey {
	return sql app.db {
		select from SshKey where user == id
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
	return app.find_user_by_id(emails[0].user)
}

pub fn (mut app App) find_user_emails(id2 int) []Email {
	emails := sql app.db {
		select from Email where user == id2
	}
	return emails
}

pub fn (mut app App) find_repo_contributor(id int) []Contributor {
	return sql app.db {
		select from Contributor where repo == id
	}
}

pub fn (mut app App) find_repo_registered_contributor(id int) []User {
	contributors := sql app.db {
		select from Contributor where repo == id
	}
	mut users := []User{cap: contributors.len}
	for contrib in contributors {
		x := app.find_user_by_id(contrib.user) or { continue }
		users << x
	}
	return users
}

pub fn (mut app App) find_registered_user() []User {
	mut users := sql app.db {
		select from User where is_registered == true
	}
	for i, user in users {
		users[i].b_avatar = user.avatar != ''
		if !users[i].b_avatar {
			users[i].avatar = user.username.bytes()[0].str()
		}
		users[i].emails = app.find_user_emails(user.id)
	}
	return users
}

pub fn (mut app App) nr_all_users() int {
	return sql app.db {
		select count from User
	}
}

pub fn (mut app App) nr_repo_contributor(id int) int {
	return sql app.db {
		select count from Contributor where repo == id
	}
}

pub fn (mut app App) inc_user_post(mut user User) {
	user.nr_posts++
	u := *user
	id := u.id
	now := int(time.now().unix)
	lastplus := int(time.unix(u.last_post_time).add_days(1).unix)
	if now >= lastplus {
		user.last_post_time = now
		sql app.db {
			update User set nr_posts = 0, last_post_time = now where id == id
		}
	}
	sql app.db {
		update User set nr_posts = nr_posts + 1 where id == id
	}
}

pub fn (mut app App) inc_user_login_attempts(user_id int) {
	sql app.db {
		update User set login_attempts = login_attempts + 1 where id == user_id
	}
}

pub fn (mut app App) update_user_login_attempts(user_id int, attempts int) {
	sql app.db {
		update User set login_attempts = attempts where id == user_id
	}
}

pub fn (mut app App) block_user(user_id int) {
	sql app.db {
		update User set is_blocked = true where id == user_id
	}
}

pub fn (mut app App) unblock_user(user_id int) {
	sql app.db {
		update User set is_blocked = false where id == user_id
	}
}

pub fn (mut app App) check_user_blocked(user_id int) bool {
	user := app.find_user_by_id(user_id) or { return false }
	return user.is_blocked
}

pub fn (mut app App) client_ip(username string) ?string {
	ip := app.conn.peer_ip() or { return none }
	return make_password(ip, '${username}token')
}

fn (mut app App) change_username(user_id int, username string) {
	sql app.db {
		update User set username = username where id == user_id
	}
	sql app.db {
		update Repo set user_name = username where user_id == user_id
	}
}

fn (mut app App) inc_namechanges(user_id int) {
	now := int(time.now().unix)
	sql app.db {
		update User set nr_namechanges = nr_namechanges + 1, last_namechange_time = now where id ==
		user_id
	}
}
