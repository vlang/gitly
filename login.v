// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import time
import rand
import math

pub fn (mut app App) login() vweb.Result {
	csrf := rand.string(30)
	app.set_cookie(name: 'csrf', value: csrf)
	nr_users := app.nr_all_users()
	println('nr_users=$nr_users')
	if app.is_logged_in() {
		return app.not_found()
	}
	return $vweb.html()
}

['/login'; post]
pub fn (mut app App) handle_login() vweb.Result {
	nr_users := app.nr_all_users()
	if app.settings.only_gh_login && nr_users != 1 {
		return app.r_home()
	}
	username := app.form['username']
	password := app.form['password']
	if username == '' || password == '' {
		return app.redirect('/login')
	}
	user := app.find_user_by_username(username) or { return app.redirect('/login') }
	// println('got user')
	// println(user)
	if user.is_blocked {
		return app.redirect('/login')
	}
	if !check_password(password, username, user.password) {
		// println('bad password')
		app.inc_user_login_attempts(user.id)
		if user.login_attempts == max_login_attempts {
			app.warn('User $user.username got blocked')
			app.block_user(user.id)
		}
		app.error('Wrong username/password')
		return app.login()
		// return app.redirect('/login')
	}
	if !user.is_registered {
		return app.redirect('/login')
	}
	ip := app.client_ip(user.id.str()) or { return app.r_home() }
	app.auth_user(user, ip)
	app.security_log(user_id: user.id, kind: .logged_in)
	return app.r_home()
}

pub fn (mut app App) auth_user(user User, ip string) {
	_ := time.utc().add_days(expire_length)
	// token := if user.token == '' { app.add_token(user.id) } else { user.token }
	token := app.add_token(user.id, ip)
	app.update_user_login_attempts(user.id, 0)
	// println('auth_user() cookie: setting token=$token id=$user.id')
	expire_date := time.now().add_days(200)
	app.set_cookie(name: 'id', value: user.id.str(), expires: expire_date)
	app.set_cookie(name: 'token', value: token, expires: expire_date)
	// app.set_cookie_with_expire_date('id', user.id.str(), expires)
	// app.set_cookie_with_expire_date('token', token, expires)
}

pub fn (mut app App) is_logged_in() bool {
	id := app.get_cookie('id') or { return false }
	token := app.get_cookie('token') or { return false }
	// println('is_logged_in() id:$id token:$token')
	ip := app.client_ip(id) or {
		println('no ip')
		return false
	}
	// println('ip=$ip')
	t := app.find_user_token(id.int(), ip)
	// println('t=$t')
	blocked := app.check_user_blocked(id.int())
	if blocked {
		app.logout()
		return false
	}
	return id != '' && token != '' && t != '' && t == token
}

pub fn (mut app App) logout() vweb.Result {
	app.set_cookie(name: 'id', value: '')
	app.set_cookie(name: 'token', value: '')
	return app.r_home()
}

pub fn (mut app App) get_user_from_cookies() ?User {
	id := app.get_cookie('id') or { return none }
	token := app.get_cookie('token') or { return none }
	mut user := app.find_user_by_id(id.int()) or { return none }
	ip := app.client_ip(id) or { return none }
	if token != app.find_user_token(user.id, ip) {
		return none
	}
	user.b_avatar = user.avatar != ''
	if !user.b_avatar {
		user.avatar = user.username[..1]
	}
	return user
}

['/register']
pub fn (mut app App) register() vweb.Result {
	no_users := app.nr_all_users() == 0
	if app.settings.only_gh_login && !no_users {
		println('only gh')
		return app.r_home()
	}
	app.path = ''
	return $vweb.html()
}

['/register_post'; post]
pub fn (mut app App) handle_register() vweb.Result {
	no_users := app.nr_all_users() == 0
	if app.settings.only_gh_login && !no_users {
		return app.r_home()
	}
	username := app.form['username']
	if username in ['login', 'register', 'new', 'new_post', 'oauth'] {
		app.error('Username `$username` is not available')
		return app.register()
	}
	user_chars := username.bytes()
	if user_chars.len > max_username_len {
		app.error('Username is too long (max. $max_username_len)')
		return app.register()
	}
	if username.contains('--') {
		app.error('Username cannot contain two hyphens')
		return app.register()
	}
	if user_chars[0] == `-` || user_chars.last() == `-` {
		app.error('Username cannot begin or end with a hyphen')
		return app.register()
	}
	for char in user_chars {
		if !char.is_letter() && !char.is_digit() && char != `-` {
			app.error('Username cannot contain special characters')
			return app.register()
		}
	}
	if app.form['password'] == '' {
		app.error('Password cannot be empty')
		return app.register()
	}
	password := make_password(app.form['password'], username)
	email := app.form['email']
	if username == '' || email == '' {
		app.error('Username or Email cannot be emtpy')
		return app.register()
	}
	if !app.add_user(username, password, [email], false, no_users) {
		app.error('Failed to register')
		return app.register()
	}
	user := app.find_user_by_username(username) or {
		app.error('User already exists')
		return app.register()
	}
	if no_users {
		app.user_set_admin(user.id)
	}
	println('register ok, logging new user in')
	ip := app.client_ip(user.id.str()) or {
		println('failed to get ip')
		app.error('Failed to register')
		return app.register()
	}
	app.auth_user(user, ip)
	app.security_log(user_id: user.id, kind: .registered)
	app.settings.only_gh_login = true
	// println('user_agent=$app.req.user_agent')
	if app.form['no_redirect'] == '1' {
		return app.text('ok')
	}
	return app.redirect('/' + username)
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
