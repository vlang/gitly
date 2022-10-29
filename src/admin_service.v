module main

pub fn (mut app App) edit_user(user_id int, delete_tokens bool, is_blocked bool, is_admin bool) {
	if is_admin {
		app.add_admin(user_id)
	} else {
		app.remove_admin(user_id)
	}

	if is_blocked {
		app.block_user(user_id)
	} else {
		app.unblock_user(user_id)
	}

	if delete_tokens {
		app.delete_tokens(user_id)
	}
}

pub fn (mut app App) block_user(user_id int) {
	app.set_user_block_status(user_id, true)
}

pub fn (mut app App) unblock_user(user_id int) {
	app.set_user_block_status(user_id, false)
}

pub fn (mut app App) add_admin(user_id int) {
	app.set_user_admin_status(user_id, true)
}

pub fn (mut app App) remove_admin(user_id int) {
	app.set_user_admin_status(user_id, false)
}

pub fn (mut app App) update_gitly_settings(oauth_client_id string, oauth_client_secret string) {
	app.update_settings(oauth_client_id, oauth_client_secret)

	app.load_settings()
}

fn (mut app App) is_admin() bool {
	return app.logged_in && app.user.is_admin
}
