// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Issue {
	id            int
mut:
	author_id     int
	repo_id       int
	is_pr         bool
	assigned      []int       [skip]
	labels        []int       [skip]
	nr_comments   int
	title         string
	text          string
	created_at    int
	status        IssueStatus [skip]
	linked_issues []int       [skip]
	author_name   string      [skip]
	repo_author   string      [skip]
	repo_name     string      [skip]
}

enum IssueStatus {
	open = 0
	closed = 1
}

struct Label {
	id    int
	name  string
	color string
}

fn (mut app App) insert_issue(issue Issue) {
	app.info('inserting issue:')
	app.info(issue.title)
	sql app.db {
		insert issue into Issue
	}
}

fn (mut app App) find_issue_by_id(issue_id int) ?Issue {
	issue := sql app.db {
		select from Issue where id == issue_id limit 1
	}
	if issue.id == 0 {
		return none
	}
	return issue
}

fn (mut app App) find_pr_by_id(issue_id int) ?Issue {
	pr := sql app.db {
		select from Issue where id == issue_id limit 1
	}
	if pr.id == 0 {
		return none
	}
	return pr
}

fn (mut app App) find_repo_issues_as_page(repo_id int, page int) []Issue {
	off := page * commits_per_page
	return sql app.db {
		select from Issue where repo_id == repo_id && is_pr == false limit 35 offset off
	}
}

fn (mut app App) find_repo_issues(repo_id int) []Issue {
	issues := sql app.db {
		select from Issue where repo_id == repo_id && is_pr == false
	}
	return issues
}

fn (mut app App) find_repo_prs(repo_id int) []Issue {
	issues := sql app.db {
		select from Issue where repo_id == repo_id && is_pr == true
	}
	return issues
}

fn (mut app App) find_user_issues(user_id int) []Issue {
	return sql app.db {
		select from Issue where author_id == user_id && is_pr == false
	}
}

fn (mut app App) delete_repo_issues(repo_id int) {
	sql app.db {
		delete from Issue where repo_id == repo_id
	}
}

fn (mut app App) inc_issue_comments(id int) {
	sql app.db {
		update Issue set nr_comments = nr_comments + 1 where id == id
	}
}

fn (i &Issue) relative_time() string {
	return time.unix(i.created_at).relative()
}
