// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import veb

enum PrStatus {
	open   = 0
	closed = 1
	merged = 2
}

struct PullRequest {
	id int @[primary; sql: serial]
mut:
	repo_id           int
	author_id         int
	title             string
	description       string
	head_branch       string
	base_branch       string
	status            int
	comments_count    int
	created_at        int
	merged_at         int
	merge_commit_hash string
	repo_author       string @[skip]
	repo_name         string @[skip]
}

struct PrComment {
	id int @[primary; sql: serial]
mut:
	pr_id      int
	author_id  int
	created_at int
	text       string
}

struct PrReview {
	id int @[primary; sql: serial]
mut:
	pr_id      int
	author_id  int
	state      int // 0 comment, 1 approved, 2 changes requested
	body       string
	created_at int
}

struct PrReviewComment {
	id int @[primary; sql: serial]
mut:
	pr_id       int
	author_id   int
	review_id   int // 0 if standalone (not part of a submitted review)
	file_path   string
	line_number int
	side        string // 'old' or 'new'
	text        string
	created_at  int
}

fn (p &PullRequest) is_open() bool {
	return p.status == int(PrStatus.open)
}

fn (p &PullRequest) is_merged() bool {
	return p.status == int(PrStatus.merged)
}

fn (p &PullRequest) is_closed() bool {
	return p.status == int(PrStatus.closed)
}

fn (p &PullRequest) status_label() string {
	return match unsafe { PrStatus(p.status) } {
		.open { 'Open' }
		.closed { 'Closed' }
		.merged { 'Merged' }
	}
}

fn (p &PullRequest) status_class() string {
	return match unsafe { PrStatus(p.status) } {
		.open { 'pr-status--open' }
		.closed { 'pr-status--closed' }
		.merged { 'pr-status--merged' }
	}
}

fn (p &PullRequest) relative_time() string {
	return time.unix(p.created_at).relative()
}

fn (p &PullRequest) formatted_title() veb.RawHtml {
	parts := p.title.split('`')
	mut out := ''
	for idx, part in parts {
		if idx % 2 == 0 {
			out += html_escape_text(part)
		} else if idx == parts.len - 1 {
			out += '`' + html_escape_text(part)
		} else {
			out += '<code>' + html_escape_text(part) + '</code>'
		}
	}
	return out
}

fn (c &PrComment) relative() string {
	return time.unix(c.created_at).relative()
}

fn (r &PrReview) relative() string {
	return time.unix(r.created_at).relative()
}

fn (r &PrReview) state_label() string {
	return match r.state {
		1 { 'approved' }
		2 { 'requested changes' }
		else { 'commented' }
	}
}

fn (r &PrReview) state_class() string {
	return match r.state {
		1 { 'pr-review--approved' }
		2 { 'pr-review--changes' }
		else { 'pr-review--comment' }
	}
}

fn (rc &PrReviewComment) relative() string {
	return time.unix(rc.created_at).relative()
}

fn (mut app App) add_pull_request(repo_id int, author_id int, title string, description string, head string, base string) !int {
	pr := PullRequest{
		repo_id:     repo_id
		author_id:   author_id
		title:       title
		description: description
		head_branch: head
		base_branch: base
		status:      int(PrStatus.open)
		created_at:  int(time.now().unix())
	}
	sql app.db {
		insert pr into PullRequest
	}!
	return db_last_insert_id(mut app.db)
}

fn (mut app App) find_pull_request_by_id(pr_id int) ?PullRequest {
	rows := sql app.db {
		select from PullRequest where id == pr_id limit 1
	} or { []PullRequest{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) find_repo_pull_requests(repo_id int, pr_status PrStatus) []PullRequest {
	wanted := int(pr_status)
	return sql app.db {
		select from PullRequest where repo_id == repo_id && status == wanted order by created_at desc
	} or { []PullRequest{} }
}

fn (mut app App) find_user_pull_requests(user_id int) []PullRequest {
	return sql app.db {
		select from PullRequest where author_id == user_id order by created_at desc
	} or { []PullRequest{} }
}

fn (mut app App) get_repo_open_pr_count(repo_id int) int {
	wanted := int(PrStatus.open)
	return sql app.db {
		select count from PullRequest where repo_id == repo_id && status == wanted
	} or { 0 }
}

fn (mut app App) set_pr_status(pr_id int, new_status PrStatus) ! {
	wanted := int(new_status)
	sql app.db {
		update PullRequest set status = wanted where id == pr_id
	}!
}

fn (mut app App) set_pr_merged(pr_id int, merge_hash string) ! {
	wanted := int(PrStatus.merged)
	merged_at := int(time.now().unix())
	sql app.db {
		update PullRequest set status = wanted, merge_commit_hash = merge_hash, merged_at = merged_at
		where id == pr_id
	}!
}

fn (mut app App) increment_pr_comments(pr_id int) ! {
	sql app.db {
		update PullRequest set comments_count = comments_count + 1 where id == pr_id
	}!
}

fn (mut app App) increment_repo_open_prs(repo_id int) ! {
	sql app.db {
		update Repo set nr_open_prs = nr_open_prs + 1 where id == repo_id
	}!
}

fn (mut app App) decrement_repo_open_prs(repo_id int) ! {
	sql app.db {
		update Repo set nr_open_prs = nr_open_prs - 1 where id == repo_id
	}!
}

fn (mut app App) add_pr_comment(pr_id int, author_id int, text string) ! {
	comment := PrComment{
		pr_id:      pr_id
		author_id:  author_id
		created_at: int(time.now().unix())
		text:       text
	}
	sql app.db {
		insert comment into PrComment
	}!
}

fn (mut app App) get_pr_comments(pr_id int) []PrComment {
	return sql app.db {
		select from PrComment where pr_id == pr_id order by created_at
	} or { []PrComment{} }
}

fn (mut app App) add_pr_review(pr_id int, author_id int, state int, body string) !int {
	review := PrReview{
		pr_id:      pr_id
		author_id:  author_id
		state:      state
		body:       body
		created_at: int(time.now().unix())
	}
	sql app.db {
		insert review into PrReview
	}!
	return db_last_insert_id(mut app.db)
}

fn (mut app App) get_pr_reviews(pr_id int) []PrReview {
	return sql app.db {
		select from PrReview where pr_id == pr_id order by created_at
	} or { []PrReview{} }
}

fn (mut app App) add_pr_review_comment(pr_id int, author_id int, review_id int, file_path string, line_number int, side string, text string) ! {
	c := PrReviewComment{
		pr_id:       pr_id
		author_id:   author_id
		review_id:   review_id
		file_path:   file_path
		line_number: line_number
		side:        side
		text:        text
		created_at:  int(time.now().unix())
	}
	sql app.db {
		insert c into PrReviewComment
	}!
}

fn (mut app App) get_pr_review_comments(pr_id int) []PrReviewComment {
	return sql app.db {
		select from PrReviewComment where pr_id == pr_id order by created_at
	} or { []PrReviewComment{} }
}

fn (mut app App) delete_repo_pull_requests(repo_id int) ! {
	prs := sql app.db {
		select from PullRequest where repo_id == repo_id
	} or { []PullRequest{} }
	for pr in prs {
		pr_id := pr.id
		sql app.db {
			delete from PrComment where pr_id == pr_id
		}!
		sql app.db {
			delete from PrReview where pr_id == pr_id
		}!
		sql app.db {
			delete from PrReviewComment where pr_id == pr_id
		}!
	}
	sql app.db {
		delete from PullRequest where repo_id == repo_id
	}!
}
