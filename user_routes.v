module main

import time
import os
import vweb
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
		app.increment_user_login_attempts(user.id)

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

	app.auth_user(user, app.ip())
	app.add_security_log(user_id: user.id, kind: .logged_in)

	return app.redirect_to_index()
}

['/logout']
pub fn (mut app App) handle_logout() vweb.Result {
	app.set_cookie(name: 'token', value: '')

	return app.redirect_to_index()
}

['/:username']
pub fn (mut app App) user(username string) vweb.Result {
	app.show_menu = false
	exists, user := app.check_username(username)

	if !exists {
		return app.not_found()
	}

	return $vweb.html()
}

['/:user/settings']
pub fn (mut app App) user_settings(user string) vweb.Result {
	return $vweb.html()
}

['/:user/settings'; post]
pub fn (mut app App) handle_update_user_settings(user string) vweb.Result {
	if !app.logged_in || user != app.user.username {
		return app.redirect_to_index()
	}

	name := if 'name' in app.form { app.form['name'] } else { '' }

	if name == '' {
		app.error('New name is empty')
		return app.user_settings(user)
	}

	if name == user {
		return app.user_settings(user)
	}

	if app.user.namechanges_count > max_namechanges {
		app.error('You can not change your username, limit reached')

		return app.user_settings(user)
	}

	if app.user.last_namechange_time == 0
		|| app.user.last_namechange_time + namechange_period <= time.now().unix {
		u := app.find_user_by_username(name) or { User{} }
		if u.id != 0 {
			app.error('Name already exists')
			return app.user_settings(user)
		}

		app.change_username(app.user.id, name)
		app.incement_namechanges(app.user.id)
		app.rename_user_directory(user, name)

		return app.redirect('/$name')
	}
	app.error('You need to wait until you can change the name again')

	return app.user_settings(user)
}

fn (mut app App) rename_user_directory(old_name string, new_name string) {
	os.mv('$app.settings.repo_storage_path/$old_name', '$app.settings.repo_storage_path/$new_name') or {
		panic(err)
	}
}

pub fn (mut app App) register() vweb.Result {
	no_users := app.get_users_count() == 0

	app.current_path = ''

	return $vweb.html()
}

['/register'; post]
pub fn (mut app App) handle_register() vweb.Result {
	no_users := app.get_users_count() == 0

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

	if !app.register_user(username, password, salt, [email], false, no_users) {
		app.error('Failed to register')
		return app.register()
	}

	user := app.find_user_by_username(username) or {
		app.error('User already exists')
		return app.register()
	}

	if no_users {
		app.add_admin(user.id)
	}

	client_ip := app.ip()

	app.auth_user(user, client_ip)
	app.add_security_log(user_id: user.id, kind: .registered)

	if app.form['no_redirect'] == '1' {
		return app.text('ok')
	}

	return app.redirect('/' + username)
}
