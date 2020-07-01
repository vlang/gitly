module main

import time

struct Release {
	id       int
	repo_id  int
mut:
	tag_id   int
	notes    string
	tag_name string [skip]
	tag_hash string [skip]
	user     string [skip]
	date     time.Time [skip]
}

pub fn (mut app App) insert_release(release Release) {
	sql app.db {
		insert release into Release
	}
}

pub fn (mut app App) find_releases_by_repo_id(repo_id int) []Release {
	return sql app.db {
		select from Release where repo_id == repo_id 
	}
}

pub fn (mut app App) count_releases_by_repo_id(repo_id int) int {
	return sql app.db {
		select count from Release where repo_id == repo_id
	}
}
