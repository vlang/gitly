// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import veb

struct Discussion {
	id int @[primary; sql: serial]
mut:
	repo_id        int
	author_id      int
	title          string
	body           string
	category       string // general, qa, announcement, idea
	is_locked      bool
	is_answered    bool
	answer_id      int
	comments_count int
	created_at     int
}

struct DiscussionComment {
	id int @[primary; sql: serial]
mut:
	discussion_id int
	author_id     int
	text          string
	created_at    int
}

fn (d &Discussion) relative_time() string {
	return time.unix(d.created_at).relative()
}

fn (d &Discussion) formatted_title() veb.RawHtml {
	return html_escape_text(d.title)
}

fn (d &Discussion) category_label() string {
	return match d.category {
		'qa' { 'Q&A' }
		'announcement' { 'Announcement' }
		'idea' { 'Idea' }
		else { 'General' }
	}
}

fn (c &DiscussionComment) relative() string {
	return time.unix(c.created_at).relative()
}

fn (mut app App) add_discussion(repo_id int, author_id int, title string, body string, category string) !int {
	d := Discussion{
		repo_id:    repo_id
		author_id:  author_id
		title:      title
		body:       body
		category:   category
		created_at: int(time.now().unix())
	}
	sql app.db {
		insert d into Discussion
	}!
	return db_last_insert_id(mut app.db)
}

fn (mut app App) find_discussion(id int) ?Discussion {
	rows := sql app.db {
		select from Discussion where id == id limit 1
	} or { []Discussion{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) list_repo_discussions(repo_id int) []Discussion {
	return sql app.db {
		select from Discussion where repo_id == repo_id order by created_at desc
	} or { []Discussion{} }
}

fn (mut app App) add_discussion_comment(discussion_id int, author_id int, text string) ! {
	c := DiscussionComment{
		discussion_id: discussion_id
		author_id:     author_id
		text:          text
		created_at:    int(time.now().unix())
	}
	sql app.db {
		insert c into DiscussionComment
	}!
	sql app.db {
		update Discussion set comments_count = comments_count + 1 where id == discussion_id
	}!
}

fn (mut app App) get_discussion_comments(discussion_id int) []DiscussionComment {
	return sql app.db {
		select from DiscussionComment where discussion_id == discussion_id order by created_at
	} or { []DiscussionComment{} }
}

fn (mut app App) set_discussion_lock(discussion_id int, locked bool) ! {
	sql app.db {
		update Discussion set is_locked = locked where id == discussion_id
	}!
}

fn (mut app App) mark_discussion_answer(discussion_id int, comment_id int) ! {
	sql app.db {
		update Discussion set is_answered = true, answer_id = comment_id where id == discussion_id
	}!
}

fn (mut app App) delete_discussion(id int) ! {
	sql app.db {
		delete from DiscussionComment where discussion_id == id
	}!
	sql app.db {
		delete from Discussion where id == id
	}!
}

fn (mut app App) delete_repo_discussions(repo_id int) ! {
	ds := app.list_repo_discussions(repo_id)
	for d in ds {
		app.delete_discussion(d.id) or {}
	}
}
