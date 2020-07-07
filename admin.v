module main

import vweb

pub fn (mut app App) admin() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return $vweb.html()
}

['/admin/settings']
pub fn (mut app App) settings() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return $vweb.html()
}

['/admin/settings_post']
pub fn (mut app App) settings_post() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return app.vweb.text('TODO')
}

['/admin/userlist']
pub fn (mut app App) userlist() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return app.vweb.text('TODO')
}

['/admin/edituser/:user']
pub fn (mut app App) edituser() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return app.vweb.text('TODO')
}

['/admin/edituser_post/:user']
pub fn (mut app App) edituser_post() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return app.vweb.text('TODO')
}

fn (mut app App) is_admin() bool {
	return app.logged_in && app.user.is_admin
}
