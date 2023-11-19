// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Tag {
	id      int @[primary; sql: serial]
	repo_id int @[unique: 'tag']
mut:
	name       string @[unique: 'tag']
	hash       string
	message    string
	user_id    int
	created_at int
}

fn (mut app App) fetch_tags(repo Repo) ! {
	tags_output := repo.git('tag --format="%(refname:lstrip=2)${log_field_separator}%(objectname)${log_field_separator}%(subject)${log_field_separator}%(authoremail)${log_field_separator}%(creatordate:rfc)"')

	for tag_output in tags_output.split_into_lines() {
		tag_parts := tag_output.split(log_field_separator)
		tag_name := tag_parts[0]
		commit_hash := tag_parts[1]
		commit_message := tag_parts[2]
		author_email := tag_parts[3]
		commit_date := time.parse_rfc2822(tag_parts[4]) or {
			app.info('Error: ${err}')
			return
		}

		user := app.get_user_by_email(author_email) or {
			User{
				username: author_email
			}
		}

		app.insert_tag_into_db(repo.id, tag_name, commit_hash, commit_message, user.id,
			int(commit_date.unix))!
	}
}

fn (mut app App) insert_tag_into_db(repo_id int, tag_name string, commit_hash string, commit_message string, user_id int, date int) ! {
	tags := sql app.db {
		select from Tag where repo_id == repo_id && name == tag_name limit 1
	} or { []Tag{} }

	if tags.len != 0 {
		return
	}

	new_tag := Tag{
		repo_id: repo_id
		name: tag_name
		hash: commit_hash
		message: commit_message
		user_id: user_id
		created_at: date
	}

	sql app.db {
		insert new_tag into Tag
	}!
}

fn (mut app App) get_all_repo_tags(repo_id int) []Tag {
	return sql app.db {
		select from Tag where repo_id == repo_id order by created_at desc
	} or { [] }
}
