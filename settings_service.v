module main

fn (mut app App) load_settings() {
	app.settings = sql app.db {
		select from GitlySettings limit 1
	}
}

fn (mut app App) update_settings() {
	id := app.settings.id
	oauth_client_id := app.settings.oauth_client_id
	oauth_client_secret := app.settings.oauth_client_secret
	repo_storage_path := app.settings.repo_storage_path

	sql app.db {
		update GitlySettings set oauth_client_id = oauth_client_id, oauth_client_secret = oauth_client_secret,
		repo_storage_path = repo_storage_path where id == id
	}
}
