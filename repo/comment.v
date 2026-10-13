// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import validation
import time

struct Comment {
mut:
	id         int @[primary; sql: serial]
	author_id  int
	issue_id   int
	created_at int
	text       string
}

@['/:username/:repo_name/comments'; post]
pub fn (mut app App) handle_add_comment(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	text := ctx.form['text']
	issue_id := ctx.form['issue_id']
	is_issue_id_empty := validation.is_string_empty(issue_id)
	if !valid_comment(text) || is_issue_id_empty || !ctx.logged_in {
		ctx.error('Issue comment is not valid')
		return app.issue(mut ctx, username, repo_name, issue_id)
	}
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	issue := app.find_issue_by_id(issue_id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr {
		return ctx.not_found()
	}
	app.add_issue_comment(ctx.user.id, issue.id, text) or {
		ctx.error('There was an error while inserting the comment')
		return app.issue(mut ctx, username, repo_name, issue_id)
	}
	// TODO: count comments
	app.increment_issue_comments(issue.id) or { app.info(err.str()) }
	app.dispatch_webhook(repo.id, 'comment', WebhookCommentPayload{
		action: 'created'
		repo:   '${username}/${repo_name}'
		target: 'issue'
		number: issue.id
		author: ctx.user.username
		text:   text
	})
	return ctx.redirect('/${username}/${repo_name}/issue/${issue_id}')
}

fn (mut app App) add_issue_comment(author_id int, issue_id int, text string) ! {
	comment := Comment{
		author_id:  author_id
		issue_id:   issue_id
		created_at: int(time.now().unix())
		text:       text
	}

	sql app.db {
		insert comment into Comment
	}!
}

fn (mut app App) get_all_issue_comments(issue_id int) []Comment {
	comments := sql app.db {
		select from Comment where issue_id == issue_id order by id
	} or { []Comment{} }

	return comments
}

fn (c Comment) relative() string {
	return time.unix(c.created_at).relative()
}
