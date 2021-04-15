// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Comment {
mut:
	id          int    [primary; sql: serial]
	author_id   int
	issue_id    int
	created_at  int
	text        string
	author_name string [skip]
}

fn (mut app App) insert_comment(comment Comment) {
	sql app.db {
		insert comment into Comment
	}
}

fn (mut app App) find_issue_comments(issue_id int) []Comment {
	mut comments := sql app.db {
		select from Comment where issue_id == issue_id
	}
	for i, comment in comments {
		comments[i].author_name = app.find_username_by_id(comment.author_id)
	}
	return comments
}

fn (comment Comment) relative() string {
	return time.unix(comment.created_at).relative()
}
