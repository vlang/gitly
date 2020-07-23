// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import time
import rand
import math

['/login']
pub fn (mut app App) login() vweb.Result {
	csrf := rand.string(30)
	app.vweb.set_cookie(name:'csrf', value:csrf)
	if app.logged_in() {
		return app.vweb.not_found()
	}
	return $vweb.html()
}

[post]
['/login']
pub fn (mut app App) handle_login() vweb.Result {
	if app.only_gh_login {
		return app.r_home()
	}
	username := app.vweb.form['username']
	password := app.vweb.form['password']
	if username == '' || password == '' {
		return app.vweb.redirect('/login')
	}
	user := app.find_user_by_username(username) or {
		return app.vweb.redirect('/login')
	}
	if user.is_blocked {
		return app.vweb.redirect('/login')
	}
	if !check_password(password, username, user.password) {
		app.inc_user_login_attempts(user.id)
		if user.login_attempts == max_login_attempts {
			app.warn('User $user.username got blocked')
			app.block_user(user.id)
		}
		return app.vweb.redirect('/login')
	}
	if !user.is_registered {
		return app.vweb.redirect('/login')
	}
	ip := app.client_ip(user.id.str()) or {
		return app.r_home()
	}
	app.auth_user(user, ip)
	app.security_log(user_id: user.id, kind: .logged_in)
	return app.r_home()
}

pub fn (mut app App) auth_user(user User, ip string) {
	_ := time.utc().add_days(expire_length)
	//token := if user.token == '' { app.add_token(user.id) } else { user.token }
	token := app.add_token(user.id, ip)
	app.update_user_login_attempts(user.id, 0)
	//println('cookie: setting token=$token id=$user.id')
	expire_date := time.now().add_days(200)
	app.vweb.set_cookie(name: 'id', value:user.id.str(), expires: expire_date)
	app.vweb.set_cookie(name:'token', value:token, expires: expire_date)
	//app.vweb.set_cookie_with_expire_date('id', user.id.str(), expires)
	//app.vweb.set_cookie_with_expire_date('token', token, expires)
}

pub fn (mut app App) logged_in() bool {
	id := app.vweb.get_cookie('id') or {
		return false
	}
	token := app.vweb.get_cookie('token') or {
		return false
	}
	ip := app.client_ip(id) or {
		return false
	}
	t := app.find_user_token(id.int(), ip)
	blocked := app.check_user_blocked(id.int())
	if blocked {
		app.logout()
		return false
	}
	return id != '' && token != '' && t != '' && t == token
}

pub fn (mut app App) logout() vweb.Result {
	app.vweb.set_cookie(name:'id', value:'')
	app.vweb.set_cookie(name:'token', value:'')
	return app.r_home()
}

pub fn (mut app App) get_user_from_cookies() ?User {
	id := app.vweb.get_cookie('id') or {
		return none
	}
	token := app.vweb.get_cookie('token') or {
		return none
	}
	mut user := app.find_user_by_id(id.int()) or {
		return none
	}
	ip := app.client_ip(id) or {
		return none
	}
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
pub fn (mut app App) register() vweb.Result {
	if app.only_gh_login {
		return app.r_home()
	}
	app.path = ''
	return $vweb.html()
}

[post]
['/register']
pub fn (mut app App) handle_register() vweb.Result {
	if app.only_gh_login {
		return app.r_home()
	}
	username := app.vweb.form['username']
	if username in ['login', 'register', 'new', 'new_post', 'oauth'] {
		app.vweb.error('Username `$username` is not available')
		return app.register()
	}
	user_chars := username.bytes()
	if user_chars.len > max_username_len {
		app.vweb.error('Username is too long (max. $max_username_len)')
		return app.register()
	}
	if username.contains('--') {
		app.vweb.error('Username cannot contain two hyphens')
		return app.register()
	}
	if user_chars[0] == `-` || user_chars.last() == `-` {
		app.vweb.error('Username cannot begin or end with a hyphen')
		return app.register()
	}
	for char in user_chars {
		if !char.is_letter() && !char.is_digit() && char != `-` {
			app.vweb.error('Username cannot contain special characters')
			return app.register()
		}
	}
	if app.vweb.form['password'] == '' {
		app.vweb.error('Password cannot be empty')
		return app.register()
	}
	password := make_password(app.vweb.form['password'], username)
	email := app.vweb.form['email']
	if username == '' || email == '' {
		app.vweb.error('Username or Email cannot be emtpy')
		return app.register()
	}
	if !app.add_user(username, password, [email], false) {
		app.vweb.error('Failed to register')
		return app.register()
	}
	user := app.find_user_by_username(username) or {
		app.vweb.error('User already exists')
		return app.register()
	}
	println("register: logging in")
	ip := app.client_ip(user.id.str()) or {
		app.vweb.error('Failed to register')
		return app.register()
	}
	app.auth_user(user, ip)
	app.security_log(user_id: user.id, kind: .registered)
	app.only_gh_login = true
	return app.vweb.redirect('/' + username)
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


