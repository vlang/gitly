// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

struct Comment {
mut:
	id          int
	author_id   int
	issue_id    int
	created_at  int
	text        string
	author_name string [skip]
}

fn (mut app App) find_issue_comments(issue_id int) []Comment {
	mut comments = sql app.db {
		select from Comment where issue_id == issue_id 
	}
	for i, comment in comments {
		comments[i].author_name = app.find_username_by_id(comment.author_id)
	}
	return commands
}
