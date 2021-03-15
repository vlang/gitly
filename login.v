// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import time
import rand
import math

['/login']
pub fn (mut app App) login(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	csrf := rand.string(30)
	c.set_cookie(name: 'csrf', value: csrf)
	if app.logged_in(mut c) {
		return c.not_found()
	}
	return $vweb.html()
}

[post]
['/login']
pub fn (mut app App) handle_login(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	if app.settings.only_gh_login {
		return app.r_home(mut c)
	}
	username := c.form['username']
	password := c.form['password']
	if username == '' || password == '' {
		return c.redirect('/login')
	}
	user := app.find_user_by_username(username) or { return c.redirect('/login') }
	if user.is_blocked {
		return c.redirect('/login')
	}
	if !check_password(password, username, user.password) {
		app.inc_user_login_attempts(user.id)
		if user.login_attempts == max_login_attempts {
			app.warn('User $user.username got blocked')
			app.block_user(user.id)
		}
		return c.redirect('/login')
	}
	if !user.is_registered {
		return c.redirect('/login')
	}
	ip := app.client_ip(c, user.id.str()) or { return app.r_home(mut c) }
	app.auth_user(mut c, user, ip)
	app.security_log(c, user_id: user.id, kind: .logged_in)
	return app.r_home(mut c)
}

pub fn (mut app App) auth_user(mut c vweb.Context, user User, ip string) {
	_ := time.utc().add_days(expire_length)
	// token := if user.token == '' { app.add_token(user.id) } else { user.token }
	token := app.add_token(user.id, ip)
	app.update_user_login_attempts(user.id, 0)
	// println('cookie: setting token=$token id=$user.id')
	expire_date := time.now().add_days(200)
	c.set_cookie(name: 'id', value: user.id.str(), expires: expire_date)
	c.set_cookie(name: 'token', value: token, expires: expire_date)
	// c.set_cookie_with_expire_date('id', user.id.str(), expires)
	// c.set_cookie_with_expire_date('token', token, expires)
}

pub fn (mut app App) logged_in(mut c vweb.Context) bool {
	id := c.get_cookie('id') or { return false }
	token := c.get_cookie('token') or { return false }
	ip := app.client_ip(c, id) or { return false }
	t := app.find_user_token(id.int(), ip)
	blocked := app.check_user_blocked(id.int())
	if blocked {
		app.logout(mut c)
		return false
	}
	return id != '' && token != '' && t != '' && t == token
}

pub fn (mut app App) logout(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	c.set_cookie(name: 'id', value: '')
	c.set_cookie(name: 'token', value: '')
	return app.r_home(mut c)
}

pub fn (mut app App) get_user_from_cookies(mut c vweb.Context) ?User {
	id := c.get_cookie('id') or { return none }
	token := c.get_cookie('token') or { return none }
	mut user := app.find_user_by_id(id.int()) or { return none }
	ip := app.client_ip(c, id) or { return none }
	if token != app.find_user_token(user.id, ip) {
		return none
	}
	user.b_avatar = user.avatar != ''
	if !user.b_avatar {
		user.avatar = user.username.bytes()[0].str()
	}
	return user
}

['/register']
pub fn (mut app App) register(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	no_users := app.nr_all_users() == 0
	if app.settings.only_gh_login && !no_users {
		println('only gh')
		return app.r_home(mut c)
	}
	sess.path = ''
	return $vweb.html()
}

[post]
['/register_post']
pub fn (mut app App) handle_register(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	no_users := app.nr_all_users() == 0
	if app.settings.only_gh_login && !no_users {
		return app.r_home(mut c)
	}
	username := c.form['username']
	if username in ['login', 'register', 'new', 'new_post', 'oauth'] {
		c.error('Username `$username` is not available')
		return app.register(mut c)
	}
	user_chars := username.bytes()
	if user_chars.len > max_username_len {
		c.error('Username is too long (max. $max_username_len)')
		return app.register(mut c)
	}
	if username.contains('--') {
		c.error('Username cannot contain two hyphens')
		return app.register(mut c)
	}
	if user_chars[0] == `-` || user_chars.last() == `-` {
		c.error('Username cannot begin or end with a hyphen')
		return app.register(mut c)
	}
	for char in user_chars {
		if !char.is_letter() && !char.is_digit() && char != `-` {
			c.error('Username cannot contain special characters')
			return app.register(mut c)
		}
	}
	if c.form['password'] == '' {
		c.error('Password cannot be empty')
		return app.register(mut c)
	}
	password := make_password(c.form['password'], username)
	email := c.form['email']
	if username == '' || email == '' {
		c.error('Username or Email cannot be emtpy')
		return app.register(mut c)
	}
	if !app.add_user(username, password, [email], false) {
		c.error('Failed to register')
		return app.register(mut c)
	}
	user := app.find_user_by_username(username) or {
		c.error('User already exists')
		return app.register(mut c)
	}
	println('register: logging in')
	ip := app.client_ip(c, user.id.str()) or {
		c.error('Failed to register')
		return app.register(mut c)
	}
	app.auth_user(mut c, user, ip)
	app.security_log(c, user_id: user.id, kind: .registered)
	app.settings.only_gh_login = true
	return c.redirect('/' + username)
}

fn gen_uuid_v4ish() string {
	// UUIDv4 format: 4-2-2-2-6 bytes per section
	a := rand.intn(math.max_i32 / 2).hex()
	b := rand.intn(math.max_i16).hex()
	c := rand.intn(math.max_i16).hex()
	d := rand.intn(math.max_i16).hex()
	e := rand.intn(math.max_i32 / 2).hex()
	f := rand.intn(math.max_i16).hex()
	return '${a:08}-${b:04}-${c:04}-${d:04}-${e:08}${f:04}'.replace(' ', '0')
}
