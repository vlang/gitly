module main

import veb
import validation
import api

@['/:username/settings/ssh-keys']
pub fn (mut app App) user_ssh_keys_list(mut ctx Context, username string) veb.Result {
	is_users_settings := username == ctx.user.username

	if !ctx.logged_in || !is_users_settings {
		return ctx.redirect_to_index()
	}

	ssh_keys := app.find_ssh_keys(ctx.user.id)

	return $veb.html()
}

@['/:username/settings/ssh-keys'; 'post']
pub fn (mut app App) handle_add_ssh_key(mut ctx Context, username string) veb.Result {
	is_users_settings := username == ctx.user.username

	if !ctx.logged_in || !is_users_settings {
		return ctx.redirect_to_index()
	}

	title := ctx.form['title']
	ssh_key := ctx.form['key']

	is_title_empty := validation.is_string_empty(title)
	is_ssh_key_empty := validation.is_string_empty(ssh_key)

	if is_title_empty {
		ctx.error('Title is empty')

		return app.user_ssh_keys_new(mut ctx, username)
	}

	if is_ssh_key_empty {
		ctx.error('SSH key is empty')

		return app.user_ssh_keys_new(mut ctx, username)
	}

	app.add_ssh_key(ctx.user.id, title, ssh_key) or {
		ctx.error(err.str())

		return app.user_ssh_keys_new(mut ctx, username)
	}

	return ctx.redirect('/${username}/settings/ssh-keys')
}

@['/:username/settings/ssh-keys/:id'; 'delete']
pub fn (mut app App) handle_remove_ssh_key(mut ctx Context, username string, id int) veb.Result {
	is_users_settings := username == ctx.user.username

	if !ctx.logged_in || !is_users_settings {
		return ctx.redirect_to_index()
	}

	app.remove_ssh_key(ctx.user.id, id) or {
		response := api.ApiErrorResponse{
			message: 'There was an error while deleting the SSH key'
		}

		return ctx.json(response)
	}

	return ctx.ok('')
}

@['/:username/settings/ssh-keys/new']
pub fn (mut app App) user_ssh_keys_new(mut ctx Context, username string) veb.Result {
	is_users_settings := username == ctx.user.username

	if !ctx.logged_in || !is_users_settings {
		return ctx.redirect_to_index()
	}

	return $veb.html()
}
