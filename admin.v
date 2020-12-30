module main

import vweb

pub fn (mut app App) admin() vweb.Result {
	if !app.is_admin() {
		return app.r_home()
	}
	return $vweb.html()
}

['/admin/settings']
pub fn (mut app App) admin_settings() vweb.Result {
	if !app.is_admin() {
		return app.r_home()
	}
	return $vweb.html()
}

[post]
['/admin/settings']
pub fn (mut app App) update_admin_settings() vweb.Result {
	if !app.is_admin() {
		return app.r_home()
	}
	oauth_client_id := app.vweb.form['oauth_client_id']
	oauth_client_secret := app.vweb.form['oauth_client_secret']
	only_gh_login := 'only_gh_login' in app.vweb.form
	repo_storage_path := app.vweb.form['repo_storage_path']

	if oauth_client_id != '' {
		app.settings.oauth_client_id = oauth_client_id
	}
	if oauth_client_secret != '' {
		app.settings.oauth_client_secret = oauth_client_secret
	}
	app.settings.only_gh_login = only_gh_login
	app.settings.repo_storage_path = repo_storage_path

	app.update_settings()

	return app.vweb.redirect('/admin')
}

['/admin/userlist']
pub fn (mut app App) admin_userlist() vweb.Result {
	if !app.is_admin() {
		return app.r_home()
	}
	// TODO add pagination
	userlist := app.find_registered_user()
	return $vweb.html()
}

[post]
['/admin/edituser/:user']
pub fn (mut app App) admin_edituser(user string) vweb.Result {
	if !app.is_admin() {
		return app.r_home()
	}
	clear_session := 'stop-session' in app.vweb.form
	is_blocked := 'is-blocked' in app.vweb.form
	is_admin := 'is-admin' in app.vweb.form
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
	return app.vweb.redirect('/admin')
}

['/admin/statics']
pub fn (mut app App) admin_statics() vweb.Result {
	if !app.is_admin() {
		return app.r_home()
	}

	return $vweb.html()
}

fn (mut app App) is_admin() bool {
	return app.logged_in && app.user.is_admin
}
