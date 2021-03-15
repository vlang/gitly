module main

import vweb

pub fn (mut app App) admin(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.is_admin(mut c) {
		return app.r_home(mut c)
	}
	return $vweb.html()
}

['/admin/settings']
pub fn (mut app App) admin_settings(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.is_admin(mut c) {
		return app.r_home(mut c)
	}
	return $vweb.html()
}

[post]
['/admin/settings']
pub fn (mut app App) update_admin_settings(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.is_admin(mut c) {
		return app.r_home(mut c)
	}
	oauth_client_id := c.form['oauth_client_id']
	oauth_client_secret := c.form['oauth_client_secret']
	only_gh_login := 'only_gh_login' in c.form
	repo_storage_path := c.form['repo_storage_path']

	if oauth_client_id != '' {
		app.settings.oauth_client_id = oauth_client_id
	}
	if oauth_client_secret != '' {
		app.settings.oauth_client_secret = oauth_client_secret
	}
	app.settings.only_gh_login = only_gh_login
	app.settings.repo_storage_path = repo_storage_path

	app.update_settings()

	return c.redirect('/admin')
}

['/admin/userlist']
pub fn (mut app App) admin_userlist(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.is_admin(mut c) {
		return app.r_home(mut c)
	}
	// TODO add pagination
	userlist := app.find_registered_user()
	return $vweb.html()
}

[post]
['/admin/edituser/:user']
pub fn (mut app App) admin_edituser(mut c vweb.Context, user string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.is_admin(mut c) {
		return app.r_home(mut c)
	}
	clear_session := 'stop-session' in c.form
	is_blocked := 'is-blocked' in c.form
	is_admin := 'is-admin' in c.form
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
	return c.redirect('/admin')
}

['/admin/statics']
pub fn (mut app App) admin_statics(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.is_admin(mut c) {
		return app.r_home(mut c)
	}

	return $vweb.html()
}

fn (mut app App) is_admin(mut c vweb.Context) bool {
	mut sess := app.get_session(mut c)
	return sess.logged_in && sess.user.is_admin
}
