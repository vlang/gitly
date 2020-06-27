// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Issue {
	id                   int
mut:
	author_id int
	repo_id int
	is_pr bool
	//author               string [skip]
	assigned             []string [skip]
	labels               []int [skip]
	nr_comments             int
	title                string
	text string
	created_at            time.Time [skip]
	status               IssueStatus [skip]
	linked_issues []int [skip]
}

enum IssueStatus {
	open
	closed
}

struct Label {
	id    int
	name  string
	color string
}

fn (mut app App) insert_issue(issue Issue) {
	println('inserting issue:')
	println(issue.title)
	sql app.db {
		insert issue into Issue
	}
}

fn (mut app App) find_issue_by_id(issue_id int) ?Issue{
	issue := sql app.db {
		select from Issue where id == issue_id limit 1
	}
	if issue.id == 0 {
		return none
	}
	return issue
}

fn (mut app App) find_pr_by_id(issue_id int) ?Issue{
	pr := sql app.db {
		select from Issue where id == issue_id limit 1
	}
	if pr.id == 0 {
		return none
	}
	return pr
}

fn (mut app App) find_issues_by_repo(repo_id int) []Issue{
	issues := sql app.db {
		select from Issue where repo_id==repo_id && is_pr==false
	}
	return issues

}

fn (mut app App) find_prs_by_repo(repo_id int) []Issue{
	issues := sql app.db {
		select from Issue where repo_id==repo_id && is_pr==true
	}
	return issues

}

fn (i &Issue) relative_time() string {
	return '1 minute ago'
}
