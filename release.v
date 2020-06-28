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
