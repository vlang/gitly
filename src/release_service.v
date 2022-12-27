module main

import time

pub fn (mut app App) add_release(tag_id int, repo_id int, date time.Time, notes string) {
	release := Release{
		tag_id: tag_id
		repo_id: repo_id
		notes: notes
		date: date
	}

	sql app.db {
		insert release into Release
	}
}

pub fn (mut app App) find_repo_releases_as_page(repo_id int, offset int) []Release {
	// FIXME: 20 -> releases_per_page
	return sql app.db {
		select from Release where repo_id == repo_id order by date desc limit 20 offset offset
	}
}

pub fn (app App) get_repo_release_count(repo_id int) int {
	return sql app.db {
		select count from Release where repo_id == repo_id
	}
}

pub fn (mut app App) delete_repo_releases(repo_id int) {
	sql app.db {
		delete from Release where repo_id == repo_id
	}
}
