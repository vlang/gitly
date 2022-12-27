module main

import vweb

const (
	admin_users_per_page = 30
)

['/admin/settings']
pub fn (mut app App) admin_settings() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	return $vweb.html()
}

['/admin/settings'; post]
pub fn (mut app App) handle_admin_update_settings(oauth_client_id string, oauth_client_secret string) vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	app.update_gitly_settings(oauth_client_id, oauth_client_secret)

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
pub fn (mut app App) admin_users_default() vweb.Result {
	return app.admin_users(0)
}

['/admin/users/:page']
pub fn (mut app App) admin_users(page int) vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	user_count := app.get_all_registered_user_count()
	offset := admin_users_per_page * page
	users := app.get_all_registered_users_as_page(offset)
	page_count := calculate_pages(user_count, admin_users_per_page)
	is_first_page := check_first_page(page)
	is_last_page := check_last_page(user_count, offset, admin_users_per_page)
	prev_page, next_page := generate_prev_next_pages(page)

	return $vweb.html()
}

['/admin/statistics']
pub fn (mut app App) admin_statistics() vweb.Result {
	if !app.is_admin() {
		return app.redirect_to_index()
	}

	return $vweb.html()
}
