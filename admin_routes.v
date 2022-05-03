module main

import vweb

['/admin']
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
pub fn (mut app App) handle_admin_update_settings() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	oauth_client_id := app.form['oauth_client_id']
	oauth_client_secret := app.form['oauth_client_secret']
	hostname := app.form['hostname']
	repo_storage_path := app.form['repo_storage_path']

	app.update_gitly_settings(oauth_client_id, oauth_client_secret, hostname, repo_storage_path)

	return app.redirect('/admin')
}

['/admin/users/:user'; post]
pub fn (mut app App) handle_admin_edit_user(user_id string) vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	clear_session := 'stop-session' in app.form
	is_blocked := 'is-blocked' in app.form
	is_admin := 'is-admin' in app.form

	app.edit_user(user_id.int(), clear_session, is_blocked, is_admin)

	return app.redirect('/admin')
}

['/admin/users']
pub fn (mut app App) admin_users() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	// TODO: add pagination
	users := app.get_all_registered_users()

	return $vweb.html()
}

['/admin/statistics']
pub fn (mut app App) admin_statistics() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	return $vweb.html()
}
