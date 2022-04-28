// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import time
import rand

pub fn (mut app App) login() vweb.Result {
	csrf := rand.string(30)
	app.set_cookie(name: 'csrf', value: csrf)

	if app.is_logged_in() {
		return app.not_found()
	}

	return $vweb.html()
}

['/login'; post]
pub fn (mut app App) handle_login() vweb.Result {
	username := app.form['username']
	password := app.form['password']

	if username == '' || password == '' {
		return app.redirect_to_login()
	}

	user := app.find_user_by_username(username) or { return app.redirect_to_login() }

	if user.is_blocked {
		return app.redirect_to_login()
	}

	if !compare_password_with_hash(password, user.salt, user.password) {
		app.inc_user_login_attempts(user.id)
		if user.login_attempts == max_login_attempts {
			app.warn('User $user.username got blocked')
			app.block_user(user.id)
		}
		app.error('Wrong username/password')

		return app.login()
	}

	if !user.is_registered {
		return app.redirect_to_login()
	}

	client_ip := app.ip()

	app.auth_user(user, client_ip)
	app.security_log(user_id: user.id, kind: .logged_in)

	return app.redirect_to_index()
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
		app.logout()

		return false
	}

	return true
}

pub fn (mut app App) logout() vweb.Result {
	app.set_cookie(name: 'token', value: '')

	return app.redirect_to_index()
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

['/register']
pub fn (mut app App) register() vweb.Result {
	no_users := app.nr_all_users() == 0
	app.path = ''
	return $vweb.html()
}

['/register_post'; post]
pub fn (mut app App) handle_register() vweb.Result {
	no_users := app.nr_all_users() == 0

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
	for ch in user_chars {
		if !ch.is_letter() && !ch.is_digit() && ch != `-` {
			app.error('Username cannot contain special characters')
			return app.register()
		}
	}
	if app.form['password'] == '' {
		app.error('Password cannot be empty')
		return app.register()
	}

	salt := generate_salt()
	password := hash_password_with_salt(app.form['password'], salt)

	email := app.form['email']
	if username == '' || email == '' {
		app.error('Username or Email cannot be emtpy')
		return app.register()
	}
	if !app.add_user(username, password, salt, [email], false, no_users) {
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

	client_ip := app.ip()

	app.auth_user(user, client_ip)
	app.security_log(user_id: user.id, kind: .registered)

	if app.form['no_redirect'] == '1' {
		return app.text('ok')
	}
	return app.redirect('/' + username)
}
