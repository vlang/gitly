module main

import vweb
import validation

['/:username/settings/ssh-keys']
pub fn (mut app App) user_ssh_keys_list(username string) vweb.Result {
	is_users_settings := username == app.user.username

	if !app.logged_in || !is_users_settings {
		return app.redirect_to_index()
	}

	ssh_keys := app.find_ssh_keys(app.user.id)

	return $vweb.html()
}

['/:username/settings/ssh-keys'; 'post']
pub fn (mut app App) handle_add_ssh_key(username string) vweb.Result {
	is_users_settings := username == app.user.username

	if !app.logged_in || !is_users_settings {
		return app.redirect_to_index()
	}

	title := app.form['title']
	ssh_key := app.form['key']

	is_title_empty := validation.is_string_empty(title)
	is_ssh_key_empty := validation.is_string_empty(ssh_key)

	if is_title_empty {
		app.error('Title is empty')

		return app.user_ssh_keys_new(username)
	}

	if is_ssh_key_empty {
		app.error('SSH key is empty')

		return app.user_ssh_keys_new(username)
	}

	app.add_ssh_key(app.user.id, title, ssh_key) or {
		app.error(err.str())

		return app.user_ssh_keys_new(username)
	}

	return app.redirect('/${username}/settings/ssh-keys')
}

['/:username/settings/ssh-keys/:id'; 'delete']
pub fn (mut app App) handle_remove_ssh_key(username string, id int) vweb.Result {
	is_users_settings := username == app.user.username

	if !app.logged_in || !is_users_settings {
		return app.redirect_to_index()
	}

	app.remove_ssh_key(app.user.id, id)

	return app.ok('')
}

['/:username/settings/ssh-keys/new']
pub fn (mut app App) user_ssh_keys_new(username string) vweb.Result {
	is_users_settings := username == app.user.username

	if !app.logged_in || !is_users_settings {
		return app.redirect_to_index()
	}

	return $vweb.html()
}
