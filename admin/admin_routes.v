module main

import veb

const admin_users_per_page = 30

// TODO move to admin controller

@['/admin/settings']
pub fn (mut app App) admin_settings(mut ctx Context) veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}

	return $veb.html('templates/admin/settings.html')
}

@['/admin/settings'; post]
pub fn (mut app App) handle_admin_update_settings(mut ctx Context, oauth_client_id string, oauth_client_secret string) veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}
	if oauth_client_id.len > 256 || oauth_client_secret.len > max_webhook_secret_len {
		ctx.error('OAuth credentials are too long')
		return app.admin_settings(mut ctx)
	}

	tree_folder_size_enabled := 'tree_folder_size_enabled' in ctx.form
	app.update_gitly_settings(oauth_client_id, oauth_client_secret, tree_folder_size_enabled) or {
		app.info(err.str())
	}

	return ctx.redirect('/admin')
}

@['/admin/users/:user'; post]
pub fn (mut app App) handle_admin_edit_user(mut ctx Context, user_id string) veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}

	clear_session := 'stop-session' in ctx.form
	is_blocked := 'is-blocked' in ctx.form
	is_admin := 'is-admin' in ctx.form
	target_id := user_id.int()
	app.get_user_by_id(target_id) or { return ctx.not_found() }

	app.edit_user(target_id, clear_session, is_blocked, is_admin) or {
		ctx.error(err.msg())
		return app.admin_users(mut ctx, '0')
	}

	return ctx.redirect('/admin')
}

@['/admin/users']
pub fn (mut app App) admin_users_default(mut ctx Context) veb.Result {
	return app.admin_users(mut ctx, '0')
}

@['/admin/users/:page']
pub fn (mut app App) admin_users(mut ctx Context, page string) veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}

	user_count := app.get_all_registered_user_count()
	page_count := calculate_pages(user_count, admin_users_per_page)
	page_i := normalize_page(page, page_count)
	offset := admin_users_per_page * page_i
	users := app.get_all_registered_users_as_page(offset)
	is_first_page := check_first_page(page_i)
	is_last_page := check_last_page(user_count, offset, admin_users_per_page)
	prev_page, next_page := generate_prev_next_pages(page_i)

	return $veb.html('templates/admin/users.html')
}

@['/admin/statistics']
pub fn (mut app App) admin_statistics() veb.Result {
	if !ctx.is_admin() {
		return ctx.redirect_to_index()
	}
	stats := app.get_admin_stats(admin_stats_days)
	return $veb.html('templates/admin/statistics.html')
}
