// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import time

pub fn (mut app App) login() vweb.Result {
	if app.logged_in() {
		return app.vweb.not_found()
	}
	return $vweb.html()
}

pub fn (mut app App) login_post() vweb.Result {
	if app.only_gh_login {
		return app.vweb.redirect('/')
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
	//mut token := app.find_user_token(user.id)
	app.auth_user(user)
	return app.vweb.redirect('/')
}

pub fn (mut app App) auth_user(user User) {
	expires := time.utc().add_days(expire_length)
	token := 	if user.token == '' { app.add_token(user.id) } else { user.token }
	app.update_user_login_attempts(user.id, 0)
	app.vweb.set_cookie_with_expire_date('id', user.id.str(), expires)
	app.vweb.set_cookie_with_expire_date('token', user.token, expires)

}

pub fn (mut app App) logged_in() bool {
	id := app.vweb.get_cookie('id') or {
		return false
	}
	token := app.vweb.get_cookie('token') or {
		return false
	}
	t := app.find_user_token(id.int())
	blocked := app.check_user_blocked(id.int())
	if blocked {
		app.logout()
		return false
	}
	return id != '' && token != '' && t != '' && t == token
}

pub fn (mut app App) logout() vweb.Result {
	app.vweb.set_cookie('id', '')
	app.vweb.set_cookie('token', '')
	return app.vweb.redirect('/')
}

pub fn (mut app App) add_token(user_id int) string {
	token := gen_uuid_v4ish()
	app.update_user_token(user_id, token)
	return token
}

pub fn (mut app App) get_user_from_cookies() ?User {
	id := app.vweb.get_cookie('id') or { return none }
	token := app.vweb.get_cookie('token') or { return none }
	mut user := app.find_user_by_id(id.int()) or { return none }
	if user.token != token {
		return none
	}
	user.b_avatar = user.avatar != ''
	if !user.b_avatar {
		user.avatar = user.username.bytes()[0].str()
	}
	return user
}



