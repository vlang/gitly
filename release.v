module main

import time

struct Release {
	id      int [primary; sql: serial]
	repo_id int [unique: 'release']
mut:
	tag_id   int [unique: 'release']
	notes    string
	tag_name string    [skip]
	tag_hash string    [skip]
	user     string    [skip]
	date     time.Time [skip]
}

pub fn (mut app App) insert_release(release Release) {
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
