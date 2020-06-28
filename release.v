module main

struct Release {
	id      int
	repo_id int
mut:
	tag_id  int
	notes   string
}

pub fn (mut app App) insert_release(release Release) {
	sql app.db {
		insert release into Release
	}
}

pub fn (mut app App) find_releases_by_repo_id(repo_id int) []Release {
	return sql app.db {
		select from Release where repo_id==repo_id
	}
}
