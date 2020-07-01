// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import crypto.sha256
import rand
import os
import net.http
import json
import vweb
import time

const (
	client_id = os.getenv('GITLY_OAUTH_CLIENT_ID')
	client_secret = os.getenv('GITLY_OAUTH_SECRET')
)

struct User {
	id            int
	name          string
	username      string
	password      string
	is_github     bool
	is_registered bool
	token         string
mut:
	posts         int
	avatar        string
	b_avatar      bool [skip]
	emails        []Email [skip]
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
	client_id string
	client_secret string
	code string
}

struct GitHubUser {
	username string [json:'login']
	name string
	email string
	avatar string [json:'avatar_url']
}

fn make_password(password, username string) string {
	mut seed := [u32(username[0]), u32(username[1])]
	rand.seed(seed)
	salt := rand.i64().str()
	pw := '$password$salt'
	return sha256.sum(pw.bytes()).hex().str()
}

fn check_password(password, username, hashed string) bool {
	return make_password(password, username) == hashed
}

pub fn (mut app App) add_user(username, password string, emails []string, github bool) {
	mut user := app.find_user_by_username(username) or { User{} }
	if user.id != 0 && !user.is_registered {
		app.error('User $username already exists')
		return

	}
	user = app.find_user_by_email(emails[0]) or { User{} }
	if user.id == 0 {
		user = User{
			username: username
			password: password
			is_registered: true
			is_github: github
		}
		app.insert_user(user)
		mut u := app.find_user_by_username(user.username) or {
			app.error('User was not inserted')
			return
		}
		if u.password != user.password || u.name != user.name {
			app.error('User was not inserted')
			return
		}
		for email in emails {
			mail := Email{
				user: u.id
				email: email
			}
			app.insert_email(mail)
		}
		u.emails = app.find_emails_by_user_id(u.id)
	} else {
		name := user.username
		if !github {
			sql app.db {
				update User set username=username, password=password, name=name, is_registered=true where id==user.id
			}
			return
		}
		if user.is_registered {
			sql app.db {
				update User set is_github = true where id==user.id
			}
			return
		}
		sql app.db {
			update User set username=username, name=name, is_registered=true, is_github = true where id==user.id
		}
	}
}

pub fn (mut app App) oauth() vweb.Result {
	code := app.vweb.req.url.all_after('code=')
	if code == '' {
		return app.vweb.not_found()
	}
	req := OAuth_Request {
		client_id: client_id
		client_secret: client_secret
		code: code
	}
	d := json.encode(req)
	resp := http.post_json('https://github.com/login/oauth/access_token', d) or {
		app.error(err)
		return app.vweb.not_found()
	}
	mut token := resp.text.find_between('access_token=', '&')
	mut request := http.new_request('get', 'https://api.github.com/user', '') or {
		app.error(err)
		return app.vweb.not_found()
	}
	request.add_header('Authorization', 'token $token')
	user_js := request.do() or {
		app.error(err)
		return app.vweb.not_found()
	}
	if user_js.status_code != 200 {
		app.error(user_js.status_code.str())
		app.error(user_js.text)
		return app.vweb.text('Can not access the API')
	}
	gh_user := json.decode(GitHubUser, user_js.text) or {
		return app.vweb.not_found()
	}
	mut user := app.find_user_by_email(gh_user.email) or { User{} }
	if !user.is_github {
		app.add_user(gh_user.username, '', [gh_user.email], true)
		user = app.find_user_by_email(gh_user.email) or {
			return app.vweb.not_found()
		}
		app.update_avatar_for_user_id(gh_user.avatar, user.id)
	}
	expires := time.utc().add_days(expire_length)
	token = app.find_token_from_user_id(user.id)
	if token == '' {
		token = app.add_token(user.id)
	}
	app.vweb.set_cookie_with_expire_date('id', user.id.str(), expires)
	app.vweb.set_cookie_with_expire_date('token', token, expires)
	app.vweb.redirect('/')
	return vweb.Result{}
}

pub fn (mut app App) update_avatar_for_user_id(data string, id int) {
	sql app.db {
		update User set avatar = data where id == id
	}
}

pub fn (mut app App) create_empty_user(username, email string) int {
	mut user := User{
		username: username
		is_registered: false
	}
	app.insert_user(user)
	u := app.find_user_by_username(user.username) or {
		app.error('User was not inserted')
		return -1
	}
	if user.username != u.username {
		app.error('User was not inserted')
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
	app.info('Insert user: $user.username')
	sql app.db {
		insert user into User
	}
}

pub fn (mut app App) insert_email(email Email) {
	app.info('Inserting email: $email.email')
	sql app.db {
		insert email into Email
	}
}

pub fn (mut app App) insert_sshkey(sshkey SshKey) {
	app.info('Inserting sshkey: $sshkey.title')
	sql app.db {
		insert sshkey into SshKey
	}
}

pub fn (mut app App) insert_contributor(contributor Contributor) {
	app.info('Inserting contributor: $contributor.user')
	sql app.db {
		insert contributor into Contributor
	}
}

pub fn (mut app App) remove_ssh_key(title string, user_id int) {
	sql app.db {
		update SshKey set is_deleted = true where title == title && user == user_id
	}
}

pub fn (mut app App) update_token_by_user_id(id int, token string) {
	sql app.db {
		update User set token = token where id == id
	}
}

pub fn (mut app App) find_sshkey_by_user_id(id int) []SshKey {
	return sql app.db {
		select from SshKey where user == id 
	}
}

pub fn (mut app App) find_token_from_user_id(id int) string {
	user := app.find_user_by_id(id)
	return user.token
}

pub fn (mut app App) find_username_by_id(id int) string {
	user := sql app.db {
		select from User where id == id limit 1 
	}
	return user.username
}

pub fn (mut app App) find_user_by_username(username2 string) ?User {
	user := sql app.db {
		select from User where username == username2 
	}
	if user.len == 0 {
		return error('User not found')
	}
	mut u := user[0]
	emails := app.find_emails_by_user_id(u.id)
	u.emails = emails
	return u
}

pub fn (mut app App) find_user_by_id(id2 int) User {
	mut user := sql app.db {
		select from User where id == id2 
	}
	emails := app.find_emails_by_user_id(user.id)
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

pub fn (mut app App) find_emails_by_user_id(id2 int) []Email {
	emails := sql app.db {
		select from Email where user == id2 
	}
	return emails
}

pub fn (mut app App) find_contributor_by_repo_id(id int) []Contributor {
	return sql app.db {
		select from Contributor where repo == id 
	}
}

pub fn (mut app App) find_registered_contributor_by_repo_id(id int) []User {
	contributor := sql app.db {
		select from Contributor where repo == id 
	}
	mut user := []User{}
	for contrib in contributor {
		user << app.find_user_by_id(contrib.user)
	}
	return user
}

pub fn (mut app App) contributor_by_repo_id_size(id int) int {
	return sql app.db {
		select count from Contributor where repo == id 
	}
}

pub fn (mut app App) inc_posts_for_user(user User) {
	user.posts++
	sql app.db {
		update User set posts = posts + 1 where id == user.id
	}
}
