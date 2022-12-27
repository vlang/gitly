module main

fn (mut app App) load_settings() {
	app.settings = sql app.db {
		select from Settings limit 1
	}
}

fn (mut app App) update_settings(oauth_client_id string, oauth_client_secret string) {
	old_settings := sql app.db {
		select from Settings limit 1
	}

	github_oauth_client_id := if oauth_client_id != '' {
		oauth_client_id
	} else {
		old_settings.oauth_client_id
	}

	github_oauth_client_secret := if oauth_client_secret != '' {
		oauth_client_secret
	} else {
		old_settings.oauth_client_secret
	}

	if old_settings.id == 0 {
		settings := Settings{
			oauth_client_id: github_oauth_client_id
			oauth_client_secret: github_oauth_client_secret
		}

		sql app.db {
			insert settings into Settings
		}
	} else {
		sql app.db {
			update Settings set oauth_client_id = github_oauth_client_id, oauth_client_secret = github_oauth_client_secret
			where id == old_settings.id
		}
	}
}
