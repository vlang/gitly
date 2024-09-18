module main

import veb

const admin_users_per_page = 30

// TODO move to admin controller

@['/admin/settings']
pub fn (mut app App) admin_settings() veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}

	return $veb.html()
}

@['/admin/settings'; post]
pub fn (mut app App) handle_admin_update_settings(oauth_client_id string, oauth_client_secret string) veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}

	app.update_gitly_settings(oauth_client_id, oauth_client_secret) or { app.info(err.str()) }

	return ctx.redirect('/admin')
}

@['/admin/users/:user'; post]
pub fn (mut app App) handle_admin_edit_user(user_id string) veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}

	clear_session := 'stop-session' in ctx.form
	is_blocked := 'is-blocked' in ctx.form
	is_admin := 'is-admin' in ctx.form

	app.edit_user(user_id.int(), clear_session, is_blocked, is_admin) or { app.info(err.str()) }

	return ctx.redirect('/admin')
}

@['/admin/users']
pub fn (mut app App) admin_users_default() veb.Result {
	return app.admin_users(0)
}

@['/admin/users/:page']
pub fn (mut app App) admin_users(page int) veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}

	user_count := app.get_all_registered_user_count()
	offset := admin_users_per_page * page
	users := app.get_all_registered_users_as_page(offset)
	page_count := calculate_pages(user_count, admin_users_per_page)
	is_first_page := check_first_page(page)
	is_last_page := check_last_page(user_count, offset, admin_users_per_page)
	prev_page, next_page := generate_prev_next_pages(page)

	return $veb.html()
}

@['/admin/statistics']
pub fn (mut app App) admin_statistics() veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}
	return $veb.html()
}
