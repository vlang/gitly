module main

import vweb
import os

pub fn (mut app App) admin() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return $vweb.html()
}

['/admin/settings']
pub fn (mut app App) admin_settings() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return $vweb.html()
}

['/admin/settings_post']
pub fn (mut app App) admin_settings_post() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return app.vweb.text('TODO')
}

['/admin/userlist']
pub fn (mut app App) admin_userlist() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return app.vweb.text('TODO')
}

['/admin/edituser/:user']
pub fn (mut app App) admin_edituser() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return app.vweb.text('TODO')
}

['/admin/edituser_post/:user']
pub fn (mut app App) admin_edituser_post() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}

	return app.vweb.text('TODO')
}

['/admin/update']
pub fn (mut app App) admin_update() vweb.Result {
	if !app.is_admin() {
		return app.vweb.redirect('/')
	}
	app.info('Update V')
	mut res := os.exec('v up') or { os.Result{exit_code: 1} }

	if res.exit_code != 0 {
		app.info('Failed to update V')
		app.info(res.output)
		return app.vweb.redirect('/')
	}

	res = os.exec('git diff') or { os.Result{exit_code: 1} }

	if res.exit_code != 0 || res.output != '' {
		app.info('Failed to update Gitly')
		return app.vweb.redirect('/')
	}

	res = os.exec('git checkout master') or { os.Result{exit_code: 1} }
	if res.exit_code != 0 {
		app.info('Failed to checkout master for Gitly')
		return app.vweb.redirect('/')
	}

	res = os.exec('git pull') or { os.Result{exit_code: 1} }
	if res.exit_code != 0 {
		app.info('Failed to update Gitly')
		app.info(res.output)
		return app.vweb.redirect('/')
	}
	app.info('Updated gitly successful')
	return app.vweb.redirect('/')
}

fn (mut app App) is_admin() bool {
	return app.logged_in && app.user.is_admin
}
