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
	assigned      []int [skip]
	labels        []int [skip]
	title         string
	text          string
	created_at    int
	status        IssueStatus [skip]
	linked_issues []int [skip]
	author_name   string [skip]
	nr_comments   int [skip]
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

fn (mut app App) find_issues_by_repo(repo_id int) []Issue {
	mut issues := sql app.db {
		select from Issue where repo_id == repo_id && is_pr == false 
	}
	for i, issue in issues {
		issues[i].nr_comments = app.count_comments_by_issue_id(issue.id)
	}
	return issues
}

fn (mut app App) find_prs_by_repo(repo_id int) []Issue {
	issues := sql app.db {
		select from Issue where repo_id == repo_id && is_pr == true 
	}
	return issues
}

fn (i &Issue) relative_time() string {
	return time.unix(i.created_at).relative()
}

fn (mut app App) count_issues_by_repo(repo_id int) int {
	return sql app.db {
		select count from Issue where repo_id == repo_id && is_pr == false
	}
}
