module main

import time

fn (mut app App) add_issue_comment(author_id int, issue_id int, text string) {
	comment := Comment{
		author_id: author_id
		issue_id: issue_id
		created_at: int(time.now().unix)
		text: text
	}

	sql app.db {
		insert comment into Comment
	}
}

fn (mut app App) get_all_issue_comments(issue_id int) []Comment {
	mut comments := sql app.db {
		select from Comment where issue_id == issue_id
	}

	return comments
}

fn (comment Comment) relative() string {
	return time.unix(comment.created_at).relative()
}
