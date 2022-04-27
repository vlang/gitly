module main

import vweb

pub fn (mut app App) admin() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	return $vweb.html()
}

['/admin/settings']
pub fn (mut app App) admin_settings() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	return $vweb.html()
}

['/admin/settings'; post]
pub fn (mut app App) update_admin_settings() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	oauth_client_id := app.form['oauth_client_id']
	oauth_client_secret := app.form['oauth_client_secret']
	hostname := app.form['hostname']
	repo_storage_path := app.form['repo_storage_path']

	if oauth_client_id != '' {
		app.settings.oauth_client_id = oauth_client_id
	}

	if oauth_client_secret != '' {
		app.settings.oauth_client_secret = oauth_client_secret
	}

	if hostname != '' {
		app.settings.hostname = hostname
	}

	app.settings.repo_storage_path = repo_storage_path

	app.update_settings()

	return app.redirect('/admin')
}

['/admin/userlist']
pub fn (mut app App) admin_userlist() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}
	// TODO: add pagination
	userlist := app.find_registered_user()

	return $vweb.html()
}

['/admin/edituser/:user'; post]
pub fn (mut app App) admin_edituser(user string) vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	clear_session := 'stop-session' in app.form
	is_blocked := 'is-blocked' in app.form
	is_admin := 'is-admin' in app.form

	if is_admin {
		app.user_set_admin(user.int())
	} else {
		app.user_unset_admin(user.int())
	}

	if is_blocked {
		app.block_user(user.int())
	} else {
		app.unblock_user(user.int())
	}

	if clear_session {
		app.clear_sessions(user.int())
	}

	return app.redirect('/admin')
}

['/admin/statics']
pub fn (mut app App) admin_statics() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	return $vweb.html()
}

fn (mut app App) is_admin() bool {
	return app.logged_in && app.user.is_admin
}
