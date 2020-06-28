// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import crypto.sha256
import rand

struct User {
	id        int
	name      string
	username  string
	password  string
	is_github bool
	avatar    string [skip]
mut:
	emails    []Email [skip]
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
	name string
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

pub fn (mut app App) add_user(username, password, gitname string, emails []string) {
	mut user := User{
		username: username
		password: password
		name: gitname
	}
	app.insert_user(user)
	u := app.find_user_by_username(user.username) or {
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
	app.update_contributor(user.name, user)
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

pub fn (mut app App) update_contributor(name string, user User) {
	sql app.db {
		update File set name = '', user = user.id where name == name
	}
}

pub fn (mut app App) remove_ssh_key(title string, user_id int) {
	sql app.db {
		update SshKey set is_deleted = true where title == title && user == user_id
	}
}

pub fn (mut app App) find_sshkey_by_user_id(id int) []SshKey {
	return sql app.db {
		select from SshKey where user == id 
	}
}

pub fn (mut app App) find_username_by_id(id int) string {
	user := sql app.db {
		select from User where id==id limit 1
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

pub fn (mut app App) find_named_contributor_by_repo_id(id int) []Contributor {
	return sql app.db {
		select from Contributor where repo == id && user == 0 
	}
}

pub fn (mut app App) find_registered_contributor_by_repo_id(id int) []User {
	contributor := sql app.db {
		select from Contributor where repo == id && name == '' 
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
