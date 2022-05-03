module main

pub fn (mut app App) add_release(tag_id int, repo_id int) {
	release := Release{
		tag_id: tag_id
		repo_id: repo_id
		notes: 'Some notes about this release...'
	}

	sql app.db {
		insert release into Release
	}
}

pub fn (mut app App) find_repo_releases(repo_id int) []Release {
	return sql app.db {
		select from Release where repo_id == repo_id
	}
}

pub fn (mut app App) delete_repo_releases(repo_id int) {
	sql app.db {
		delete from Release where repo_id == repo_id
	}
}
