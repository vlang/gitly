module main

import time
import os
import vweb
import rand
import validation

pub fn (mut app App) login() vweb.Result {
	csrf := rand.string(30)
	app.set_cookie(name: 'csrf', value: csrf)

	if app.is_logged_in() {
		return app.not_found()
	}

	return $vweb.html()
}

['/login'; post]
pub fn (mut app App) handle_login(username string, password string) vweb.Result {
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

	is_page_owner := username == app.user.username
	repos := if is_page_owner {
		app.find_user_repos(user.id)
	} else {
		app.find_user_public_repos(user.id)
	}

	activities := app.find_activities(user.id)

	return $vweb.html()
}

['/:username/settings']
pub fn (mut app App) user_settings(username string) vweb.Result {
	is_users_settings := username == app.user.username

	if !app.logged_in || !is_users_settings {
		return app.redirect_to_index()
	}

	return $vweb.html()
}

['/:username/settings'; post]
pub fn (mut app App) handle_update_user_settings(username string) vweb.Result {
	is_users_settings := username == app.user.username

	if !app.logged_in || !is_users_settings {
		return app.redirect_to_index()
	}

	// TODO: uneven parameters count (2) in `handle_update_user_settings`, compared to the vweb route `['/:user/settings', 'post']` (1)
	new_username := app.form['name']
	full_name := app.form['full_name']

	is_username_empty := validation.is_string_empty(new_username)

	if is_username_empty {
		app.error('New name is empty')

		return app.user_settings(username)
	}

	if app.user.namechanges_count > max_namechanges {
		app.error('You can not change your username, limit reached')

		return app.user_settings(username)
	}

	is_username_valid := validation.is_username_valid(new_username)

	if !is_username_valid {
		app.error('New username is not valid')

		return app.user_settings(username)
	}

	is_first_namechange := app.user.last_namechange_time == 0
	can_change_usernane := app.user.last_namechange_time + namechange_period <= time.now().unix

	if !(is_first_namechange || can_change_usernane) {
		app.error('You need to wait until you can change the name again')

		return app.user_settings(username)
	}

	is_new_username := new_username != username
	is_new_full_name := full_name != app.user.full_name

	if is_new_full_name {
		app.change_full_name(app.user.id, full_name)
	}

	if is_new_username {
		user := app.find_user_by_username(new_username) or { User{} }

		if user.id != 0 {
			app.error('Name already exists')

			return app.user_settings(username)
		}

		app.change_username(app.user.id, new_username)
		app.incement_namechanges(app.user.id)
		app.rename_user_directory(username, new_username)
	}

	return app.redirect('/$new_username')
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
pub fn (mut app App) handle_register(username string, email string, password string, no_redirect string) vweb.Result {
	no_users := app.get_users_count() == 0

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

	is_username_valid := validation.is_username_valid(username)

	if !is_username_valid {
		app.error('Username is not valid')

		return app.register()
	}

	if password == '' {
		app.error('Password cannot be empty')

		return app.register()
	}

	salt := generate_salt()
	hashed_password := hash_password_with_salt(password, salt)

	if username == '' || email == '' {
		app.error('Username or Email cannot be emtpy')
		return app.register()
	}

	if !app.register_user(username, hashed_password, salt, [email], false, no_users) {
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

	if no_redirect == '1' {
		return app.text('ok')
	}

	return app.redirect('/' + username)
}
