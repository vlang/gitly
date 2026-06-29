// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import veb
import highlight

struct Issue {
	id int @[primary; sql: serial]
mut:
	author_id      int
	repo_id        int
	is_pr          bool
	assigned       []int   @[skip]
	labels         []Label @[skip]
	comments_count int
	title          string
	text           string
	created_at     int
	status         IssueStatus @[skip]
	linked_issues  []int       @[skip]
	repo_author    string      @[skip]
	repo_name      string      @[skip]
}

enum IssueStatus {
	open   = 0
	closed = 1
}

struct Label {
	id int @[primary; sql: serial]
mut:
	repo_id int
	name    string
	color   string
}

struct IssueLabel {
	id int @[primary; sql: serial]
mut:
	issue_id int
	label_id int
}

fn (mut app App) add_issue(repo_id int, author_id int, title string, text string) ! {
	app.add_issue_returning_id(repo_id, author_id, title, text)!
}

fn (mut app App) add_issue_returning_id(repo_id int, author_id int, title string, text string) !int {
	return app.add_imported_issue_returning_id(repo_id, author_id, title, text,
		int(time.now().unix()))!
}

fn (mut app App) add_imported_issue_returning_id(repo_id int, author_id int, title string, text string, created_at int) !int {
	issue := Issue{
		title:      title
		text:       text
		repo_id:    repo_id
		author_id:  author_id
		created_at: created_at
	}

	sql app.db {
		insert issue into Issue
	}!
	return db_last_insert_id(mut app.db)
}

fn (mut app App) find_or_create_label(repo_id int, name string, color string) !int {
	existing := sql app.db {
		select from Label where repo_id == repo_id && name == name limit 1
	} or { []Label{} }
	if existing.len > 0 {
		return existing[0].id
	}
	label := Label{
		repo_id: repo_id
		name:    name
		color:   color
	}
	sql app.db {
		insert label into Label
	}!
	return db_last_insert_id(mut app.db)
}

fn (mut app App) add_issue_label(issue_id int, label_id int) ! {
	existing := sql app.db {
		select from IssueLabel where issue_id == issue_id && label_id == label_id limit 1
	} or { []IssueLabel{} }
	if existing.len > 0 {
		return
	}
	link := IssueLabel{
		issue_id: issue_id
		label_id: label_id
	}
	sql app.db {
		insert link into IssueLabel
	}!
}

fn (app &App) get_issue_labels(issue_id int) []Label {
	links := sql app.db {
		select from IssueLabel where issue_id == issue_id
	} or { []IssueLabel{} }
	mut labels := []Label{cap: links.len}
	for link in links {
		label := sql app.db {
			select from Label where id == link.label_id limit 1
		} or { []Label{} }
		if label.len > 0 {
			labels << label[0]
		}
	}
	return labels
}

fn (mut app App) find_issue_by_id(issue_id int) ?Issue {
	issues := sql app.db {
		select from Issue where id == issue_id limit 1
	} or { []Issue{} }
	if issues.len == 0 {
		return none
	}
	return issues.first()
}

fn (mut app App) find_repo_issues_as_page(repo_id int, page int) []Issue {
	off := page * commits_per_page
	return sql app.db {
		select from Issue where repo_id == repo_id && is_pr == false order by created_at desc limit commits_per_page offset off
	} or { []Issue{} }
}

fn (mut app App) get_repo_issue_count(repo_id int) int {
	return sql app.db {
		select count from Issue where repo_id == repo_id && is_pr == false
	} or { 0 }
}

fn (mut app App) sync_repo_open_issue_count(repo_id int) ! {
	open_issues_count := app.get_repo_issue_count(repo_id)
	sql app.db {
		update Repo set nr_open_issues = open_issues_count where id == repo_id
	}!
}

fn placeholder_user(user_id int) User {
	username := if user_id > 0 { 'user-${user_id}' } else { 'unknown-user' }
	return User{
		id:       user_id
		username: username
		avatar:   default_avatar_name
	}
}

fn (mut app App) find_user_issues(user_id int) []Issue {
	return sql app.db {
		select from Issue where author_id == user_id && is_pr == false order by created_at desc
	} or { []Issue{} }
}

fn (mut app App) find_user_mentioned_issues(username string) []Issue {
	needle := '@' + username
	mut seen := map[int]bool{}
	mut result := []Issue{}
	direct_rows := db_exec_values(mut app.db,
		'select id from ${sql_table('Issue')} where is_pr = 0 and text like ${sql_like_pattern(needle)} order by created_at desc') or {
		[][]string{}
	}
	for row in direct_rows {
		id := row[0].int()
		if id in seen {
			continue
		}
		issue := app.find_issue_by_id(id) or { continue }
		seen[id] = true
		result << issue
	}
	comment_rows := db_exec_values(mut app.db,
		'select distinct issue_id from ${sql_table('Comment')} where text like ${sql_like_pattern(needle)}') or {
		[][]string{}
	}
	for row in comment_rows {
		id := row[0].int()
		if id in seen {
			continue
		}
		issue := app.find_issue_by_id(id) or { continue }
		if issue.is_pr {
			continue
		}
		seen[id] = true
		result << issue
	}
	result.sort(a.created_at > b.created_at)
	return result
}

fn (mut app App) find_user_recent_issues(user_id int) []Issue {
	mut seen := map[int]bool{}
	mut result := []Issue{}
	authored := app.find_user_issues(user_id)
	for issue in authored {
		if issue.id in seen {
			continue
		}
		seen[issue.id] = true
		result << issue
	}
	comment_rows := db_exec_values(mut app.db,
		'select distinct issue_id from ${sql_table('Comment')} where author_id = ${user_id}') or {
		[][]string{}
	}
	for row in comment_rows {
		id := row[0].int()
		if id in seen {
			continue
		}
		issue := app.find_issue_by_id(id) or { continue }
		if issue.is_pr {
			continue
		}
		seen[id] = true
		result << issue
	}
	result.sort(a.created_at > b.created_at)
	return result
}

fn (mut app App) delete_repo_issues(repo_id int) ! {
	sql app.db {
		delete from Issue where repo_id == repo_id
	}!
}

fn (mut app App) increment_issue_comments(id int) ! {
	sql app.db {
		update Issue set comments_count = comments_count + 1 where id == id
	}!
}

fn (i &Issue) relative_time() string {
	return time.unix(i.created_at).relative()
}

fn html_escape_text(s string) string {
	return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')
}

// formatted_title renders the issue title as inline markdown so titles like
// `unknown method or field: ` + "`db.pg.Row.val`" + `` get <code> spans and
// other inline markup. The wrapping <p> tag added by the markdown converter is
// stripped so the title stays inline.
fn (i &Issue) formatted_title() veb.RawHtml {
	rendered := highlight.convert_markdown_to_html(i.title).trim_space()
	if rendered.starts_with('<p>') && rendered.ends_with('</p>') {
		return rendered[3..rendered.len - 4]
	}
	return rendered
}

// formatted_body renders the issue text as markdown.
fn (i &Issue) formatted_body() veb.RawHtml {
	return highlight.convert_markdown_to_html(i.text)
}
