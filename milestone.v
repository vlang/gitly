// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Milestone {
	id int @[primary; sql: serial]
mut:
	repo_id     int
	title       string
	description string
	due_date    int // unix seconds, 0 if not set
	is_closed   bool
	created_at  int
}

fn (m &Milestone) status_label() string {
	return if m.is_closed { 'milestone_status_closed' } else { 'milestone_status_open' }
}

fn (m &Milestone) due_date_str() string {
	if m.due_date == 0 {
		return ''
	}
	t := time.unix(m.due_date)
	return '${t.year:04d}-${t.month:02d}-${t.day:02d}'
}

fn (mut app App) add_milestone(repo_id int, title string, description string, due_date int) !int {
	m := Milestone{
		repo_id:     repo_id
		title:       title
		description: description
		due_date:    due_date
		created_at:  int(time.now().unix())
	}
	sql app.db {
		insert m into Milestone
	}!
	return db_last_insert_id(mut app.db)
}

fn (mut app App) list_repo_milestones(repo_id int) []Milestone {
	return sql app.db {
		select from Milestone where repo_id == repo_id order by id desc
	} or { []Milestone{} }
}

fn (mut app App) find_milestone(id int) ?Milestone {
	rows := sql app.db {
		select from Milestone where id == id limit 1
	} or { []Milestone{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) set_milestone_closed(id int, closed bool) ! {
	sql app.db {
		update Milestone set is_closed = closed where id == id
	}!
}

fn (mut app App) delete_milestone(id int) ! {
	sql app.db {
		delete from Milestone where id == id
	}!
}

fn (mut app App) delete_repo_milestones(repo_id int) ! {
	sql app.db {
		delete from Milestone where repo_id == repo_id
	}!
}

fn parse_yyyy_mm_dd(s string) int {
	if s == '' {
		return 0
	}
	t := time.parse_iso8601(s + 'T00:00:00Z') or { time.parse(s) or { return 0 } }
	return int(t.unix())
}
