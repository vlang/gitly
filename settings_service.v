module main

fn (mut app App) load_settings() {
	app.settings = sql app.db {
		select from GitlySettings limit 1
	}
}

fn (mut app App) update_settings(oauth_client_id string, oauth_client_secret string, hostname string, repo_storage_path string) {
	old_settings := sql app.db {
		select from GitlySettings limit 1
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

	gitly_hostname := if hostname != '' { hostname } else { old_settings.hostname }

	gitly_repo_storage_path := if repo_storage_path != '' {
		repo_storage_path
	} else {
		old_settings.repo_storage_path
	}

	if old_settings.id == 0 {
		settings := GitlySettings{
			oauth_client_id: github_oauth_client_id
			oauth_client_secret: github_oauth_client_secret
			repo_storage_path: gitly_repo_storage_path
			hostname: gitly_hostname
		}

		sql app.db {
			insert settings into GitlySettings
		}
	} else {
		sql app.db {
			update GitlySettings set oauth_client_id = github_oauth_client_id, oauth_client_secret = github_oauth_client_secret,
			repo_storage_path = gitly_repo_storage_path, hostname = gitly_hostname where id == old_settings.id
		}
	}
}
