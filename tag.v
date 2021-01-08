// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Tag {
	id      int
	repo_id int
mut:
	name    string // tag name
	hash    string // hash of latest commit on tag
	user_id int // id of user that created the tag
	date    int // time of latest commit on tag
}

fn (mut app App) init_tags(mut r Repo) {
	mut tag := Tag{
		repo_id: r.id
	}
	data := r.git('ls-remote -tq')
	app.db.exec('BEGIN TRANSACTION')
	for remote_tag in data.split_into_lines() {
		tag.name = remote_tag.after('refs/tags/')
		tag.hash = remote_tag.substr(0, 7)
		tag_hash_data := r.git('log -1 --pretty="%aE$log_field_separator%cD" $tag.hash')
		args := tag_hash_data.split(log_field_separator)
		if args.len < 2 {
			continue
		}
		user := app.find_user_by_email(args[0]) or { User{
			id: 0
		} }
		tag.user_id = user.id
		date := time.parse_rfc2822(args[1]) or {
			eprintln('Error: $err')
			return
		}
		tag.date = date.unix_time()
		app.insert_tag(tag)
		r.nr_tags++
	}
	app.db.exec('END TRANSACTION')
}

pub fn (mut app App) insert_tag(tag Tag) {
	println('Insert tag: $tag.name')
	sql app.db {
		insert tag into Tag
	}
}

pub fn (mut app App) find_tag_by_name(name string) Tag {
	mut tag := sql app.db {
		select from Tag where name == name
	}
	return tag[0]
}

pub fn (mut app App) find_tag_by_id(id int) Tag {
	mut tag := sql app.db {
		select from Tag where id == id
	}
	return tag
}

pub fn (mut app App) find_repo_tags(repo_id int) []Tag {
	return sql app.db {
		select from Tag where repo_id == repo_id order by date desc
	}
}
