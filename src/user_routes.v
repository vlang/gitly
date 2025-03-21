module main

import time
import os
import veb
import rand
import validation
import api

pub fn (mut app App) login(mut ctx Context) veb.Result {
	csrf := rand.string(30)
	ctx.set_cookie(name: 'csrf', value: csrf)

	if !app.is_logged_in(mut ctx) {
		return ctx.not_found()
	}

	return $veb.html()
}

@['/login'; post]
pub fn (mut app App) handle_login(mut ctx Context, username string, password string) veb.Result {
	if username == '' || password == '' {
		return ctx.redirect_to_login()
	}
	user := app.get_user_by_username(username) or { return ctx.redirect_to_login() }
	if user.is_blocked {
		return ctx.redirect_to_login()
	}
	if !compare_password_with_hash(password, user.salt, user.password) {
		app.increment_user_login_attempts(user.id) or {
			ctx.error('There was an error while logging in')
			return app.login(mut ctx)
		}
		if user.login_attempts == max_login_attempts {
			app.warn('User ${user.username} got blocked')
			app.block_user(user.id) or { app.info(err.str()) }
		}
		ctx.error('Wrong username/password')
		return app.login(mut ctx)
	}
	if !user.is_registered {
		return ctx.redirect_to_login()
	}
	app.auth_user(mut ctx, user, ctx.ip()) or {
		ctx.error('There was an error while logging in')
		return app.login(mut ctx)
	}
	app.add_security_log(user_id: user.id, kind: .logged_in) or { app.info(err.str()) }
	return ctx.redirect('/${username}')
}

@['/logout']
pub fn (mut app App) handle_logout(mut ctx Context) veb.Result {
	ctx.set_cookie(name: 'token', value: '')
	return ctx.redirect_to_index()
}

@['/:username']
pub fn (mut app App) user(mut ctx Context, username string) veb.Result {
	exists, user := app.check_username(username)
	if !exists {
		return ctx.not_found()
	}
	is_page_owner := username == ctx.user.username
	repos := if is_page_owner {
		app.find_user_repos(user.id)
	} else {
		app.find_user_public_repos(user.id)
	}
	activities := app.find_activities(user.id)
	return $veb.html()
}

@['/:username/settings']
pub fn (mut app App) user_settings(mut ctx Context, username string) veb.Result {
	is_users_settings := username == ctx.user.username

	if !ctx.logged_in || !is_users_settings {
		return ctx.redirect_to_index()
	}

	return $veb.html()
}

@['/:username/settings'; post]
pub fn (mut app App) handle_update_user_settings(mut ctx Context, username string) veb.Result {
	is_users_settings := username == ctx.user.username

	if !ctx.logged_in || !is_users_settings {
		return ctx.redirect_to_index()
	}

	// TODO: uneven parameters count (2) in `handle_update_user_settings`, compared to the vweb route `['/:user/settings', 'post']` (1)
	new_username := ctx.form['name']
	full_name := ctx.form['full_name']

	is_username_empty := validation.is_string_empty(new_username)

	if is_username_empty {
		ctx.error('New name is empty')

		return app.user_settings(mut ctx, username)
	}

	if ctx.user.namechanges_count > max_namechanges {
		ctx.error('You can not change your username, limit reached')

		return app.user_settings(mut ctx, username)
	}

	is_username_valid := validation.is_username_valid(new_username)

	if !is_username_valid {
		ctx.error('New username is not valid')

		return app.user_settings(mut ctx, username)
	}

	is_first_namechange := ctx.user.last_namechange_time == 0
	can_change_usernane := ctx.user.last_namechange_time + namechange_period <= time.now().unix()

	if !(is_first_namechange || can_change_usernane) {
		ctx.error('You need to wait until you can change the name again')

		return app.user_settings(mut ctx, username)
	}

	is_new_username := new_username != username
	is_new_full_name := full_name != ctx.user.full_name

	if is_new_full_name {
		app.change_full_name(ctx.user.id, full_name) or {
			ctx.error('There was an error while updating the settings')
			return app.user_settings(mut ctx, username)
		}
	}

	if is_new_username {
		user := app.get_user_by_username(new_username) or { User{} }

		if user.id != 0 {
			ctx.error('Name already exists')

			return app.user_settings(mut ctx, username)
		}

		app.change_username(ctx.user.id, new_username) or {
			ctx.error('There was an error while updating the settings')
			return app.user_settings(mut ctx, username)
		}
		app.incement_namechanges(ctx.user.id) or {
			ctx.error('There was an error while updating the settings')
			return app.user_settings(mut ctx, username)
		}
		app.rename_user_directory(username, new_username)
	}

	return ctx.redirect('/${new_username}')
}

fn (mut app App) rename_user_directory(old_name string, new_name string) {
	os.mv('${app.config.repo_storage_path}/${old_name}', '${app.config.repo_storage_path}/${new_name}') or {
		panic(err)
	}
}

pub fn (mut app App) register(mut ctx Context) veb.Result {
	user_count := app.get_users_count() or { 0 }
	no_users := user_count == 0

	ctx.current_path = ''

	return $veb.html()
}

@['/register'; post]
pub fn (mut app App) handle_register(mut ctx Context, username string, email string, password string, no_redirect string) veb.Result {
	user_count := app.get_users_count() or {
		ctx.error('Failed to register')
		return app.register(mut ctx)
	}
	no_users := user_count == 0

	if username in ['login', 'register', 'new', 'new_post', 'oauth'] {
		ctx.error('Username `${username}` is not available')
		return app.register(mut ctx)
	}

	user_chars := username.bytes()

	if user_chars.len > max_username_len {
		ctx.error('Username is too long (max. ${max_username_len})')
		return app.register(mut ctx)
	}

	if username.contains('--') {
		ctx.error('Username cannot contain two hyphens')
		return app.register(mut ctx)
	}

	if user_chars[0] == `-` || user_chars.last() == `-` {
		ctx.error('Username cannot begin or end with a hyphen')
		return app.register(mut ctx)
	}

	for ch in user_chars {
		if !ch.is_letter() && !ch.is_digit() && ch != `-` {
			ctx.error('Username cannot contain special characters')
			return app.register(mut ctx)
		}
	}

	is_username_valid := validation.is_username_valid(username)

	if !is_username_valid {
		ctx.error('Username is not valid')

		return app.register(mut ctx)
	}

	if password == '' {
		ctx.error('Password cannot be empty')

		return app.register(mut ctx)
	}

	salt := generate_salt()
	hashed_password := hash_password_with_salt(password, salt)

	if username == '' || email == '' {
		ctx.error('Username or Email cannot be emtpy')
		return app.register(mut ctx)
	}

	// TODO: refactor
	is_registered := app.register_user(username, hashed_password, salt, [email], false,
		no_users) or {
		ctx.error('Failed to register')
		return app.register(mut ctx)
	}

	if !is_registered {
		ctx.error('Failed to register')
		return app.register(mut ctx)
	}

	user := app.get_user_by_username(username) or {
		ctx.error('User already exists')
		return app.register(mut ctx)
	}

	if no_users {
		app.add_admin(user.id) or { app.info(err.str()) }
	}

	client_ip := ctx.ip()

	app.auth_user(mut ctx, user, client_ip) or {
		ctx.error('Failed to register')
		return app.register(mut ctx)
	}
	app.add_security_log(user_id: user.id, kind: .registered) or { app.info(err.str()) }

	if no_redirect == '1' {
		return ctx.text('ok')
	}

	return ctx.redirect('/' + username)
}

@['/api/v1/users/avatar'; post]
pub fn (mut app App) handle_upload_avatar(mut ctx Context) veb.Result {
	if !ctx.logged_in {
		return ctx.not_found()
	}

	avatar := ctx.files['file'].first()
	file_content_type := avatar.content_type
	file_content := avatar.data

	file_extension := extract_file_extension_from_mime_type(file_content_type) or {
		response := api.ApiErrorResponse{
			message: err.str()
		}

		return ctx.json(response)
	}

	is_content_size_valid := validate_avatar_file_size(file_content)

	if !is_content_size_valid {
		response := api.ApiErrorResponse{
			message: 'This file is too large to be uploaded'
		}

		return ctx.json(response)
	}

	username := ctx.user.username
	avatar_filename := '${username}.${file_extension}'

	app.write_user_avatar(avatar_filename, file_content)
	app.update_user_avatar(ctx.user.id, avatar_filename) or {
		response := api.ApiErrorResponse{
			message: 'There was an error while updating the avatar'
		}

		return ctx.json(response)
	}

	avatar_file_path := app.build_avatar_file_path(avatar_filename)
	avatar_file_url := app.build_avatar_file_url(avatar_filename)

	app.serve_static(avatar_file_url, avatar_file_path) or { panic(err) }

	response := api.ApiResponse{
		success: true
	}

	return ctx.json(response)
}
