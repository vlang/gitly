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

['/admin/settings_post']
pub fn (mut app App) admin_settings_post() vweb.Result {
	if !app.is_admin() {
		return app.r_home()
	}

	return app.vweb.text('TODO')
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

['/admin/edituser_post/:user']
pub fn (mut app App) admin_edituser_post(user string) vweb.Result {
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

fn (mut app App) is_admin() bool {
	return app.logged_in && app.user.is_admin
}
