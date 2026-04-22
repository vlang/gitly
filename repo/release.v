module main

import time

struct Release {
	id      int @[primary; sql: serial]
	repo_id int @[unique: 'release']
mut:
	tag_id   int @[unique: 'release']
	notes    string
	tag_name string @[skip]
	tag_hash string @[skip]
	user     string @[skip]
	date     time.Time
}

pub fn (mut app App) add_release(tag_id int, repo_id int, date time.Time, notes string) ! {
	release := Release{
		tag_id:  tag_id
		repo_id: repo_id
		notes:   notes
		date:    date
	}

	sql app.db {
		insert release into Release
	}!
}

pub fn (mut app App) find_repo_releases_as_page(repo_id int, offset int) []Release {
	// FIXME: 20 -> releases_per_page
	return sql app.db {
		select from Release where repo_id == repo_id order by date desc limit 20 offset offset
	} or { []Release{} }
}

pub fn (app App) get_repo_release_count(repo_id int) int {
	return sql app.db {
		select count from Release where repo_id == repo_id
	} or { 0 }
}

pub fn (mut app App) delete_repo_releases(repo_id int) ! {
	sql app.db {
		delete from Release where repo_id == repo_id
	}!
}
