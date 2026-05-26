// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Commit {
mut:
	id         int @[primary; sql: serial]
	author_id  int
	author     string
	hash       string @[unique: 'commit']
	created_at int
	repo_id    int @[unique: 'commit']
	message    string
}

struct BranchCommit {
mut:
	id        int @[primary; sql: serial]
	branch_id int @[unique: 'branch_commit']
	commit_id int @[unique: 'branch_commit']
}

fn (commit Commit) relative() string {
	return time.unix(commit.created_at).relative()
}

fn (commit Commit) short_hash() string {
	if commit.hash.len <= 7 {
		return commit.hash
	}
	return commit.hash[..7]
}

fn row_to_commit(row []string) Commit {
	if row.len < 7 {
		return Commit{}
	}
	return Commit{
		id:         row[0].int()
		author_id:  row[1].int()
		author:     row[2]
		hash:       row[3]
		created_at: row[4].int()
		repo_id:    row[5].int()
		message:    row[6]
	}
}

const commit_select_cols = 'c.id, c.author_id, c.author, c.hash, c.created_at, c.repo_id, c.message'

fn (mut app App) commit_exists(repo_id int, branch_id int, hash string) bool {
	rows := db_exec_values(mut app.db,
		'select 1 from ${sql_table('Commit')} c join ${sql_table('BranchCommit')} bc on bc.commit_id = c.id where c.repo_id = ${repo_id} and bc.branch_id = ${branch_id} and c.hash = ${sql_literal(hash)} limit 1') or {
		return false
	}
	return rows.len > 0
}

fn (mut app App) add_commit(repo_id int, branch_id int, last_hash string, author string, author_id int, message string, date int) ! {
	mut existing := app.find_repo_commit_by_hash(repo_id, last_hash)
	mut commit_id := existing.id
	if commit_id == 0 {
		new_commit := Commit{
			author_id:  author_id
			author:     author
			hash:       last_hash
			created_at: date
			repo_id:    repo_id
			message:    message
		}
		sql app.db {
			insert new_commit into Commit
		}!
		commit_id = db_last_insert_id(mut app.db)
	}
	link := BranchCommit{
		branch_id: branch_id
		commit_id: commit_id
	}
	sql app.db {
		insert link into BranchCommit
	}!
}

fn (mut app App) find_repo_commits_as_page(repo_id int, branch_id int, offset int) []Commit {
	rows := db_exec_values(mut app.db,
		'select ${commit_select_cols} from ${sql_table('Commit')} c join ${sql_table('BranchCommit')} bc on bc.commit_id = c.id where c.repo_id = ${repo_id} and bc.branch_id = ${branch_id} order by c.created_at desc limit 35 offset ${offset}') or {
		return []Commit{}
	}
	mut commits := []Commit{cap: rows.len}
	for row in rows {
		commits << row_to_commit(row)
	}
	return commits
}

fn (mut app App) get_repo_commit_count(repo_id int, branch_id int) int {
	rows := db_exec_values(mut app.db,
		'select count(*) from ${sql_table('BranchCommit')} where branch_id = ${branch_id}') or {
		return 0
	}
	if rows.len == 0 || rows[0].len == 0 {
		return 0
	}
	return rows[0][0].int()
}

fn (mut app App) find_repo_commit_by_hash(repo_id int, hash string) Commit {
	commits := sql app.db {
		select from Commit where repo_id == repo_id && hash == hash
	} or { []Commit{} }
	if commits.len == 1 {
		return commits[0]
	}
	return Commit{}
}

fn (mut app App) find_repo_last_commit(repo_id int, branch_id int) Commit {
	rows := db_exec_values(mut app.db,
		'select ${commit_select_cols} from ${sql_table('Commit')} c join ${sql_table('BranchCommit')} bc on bc.commit_id = c.id where c.repo_id = ${repo_id} and bc.branch_id = ${branch_id} order by c.created_at desc limit 1') or {
		return Commit{}
	}
	if rows.len == 0 {
		return Commit{}
	}
	return row_to_commit(rows[0])
}

fn (app App) find_repo_last_commit_time(repo_id int) int {
	commits := sql app.db {
		select from Commit where repo_id == repo_id order by created_at desc limit 1
	} or { return 0 }
	if commits.len == 0 {
		return 0
	}
	return commits[0].created_at
}

const activity_weeks = 12

fn (app App) get_repo_activity_buckets(repo_id int) []int {
	week_seconds := 7 * 24 * 3600
	now := int(time.now().unix())
	cutoff := now - activity_weeks * week_seconds
	commits := sql app.db {
		select from Commit where repo_id == repo_id && created_at >= cutoff
	} or { []Commit{} }
	mut buckets := []int{len: activity_weeks}
	for c in commits {
		idx := (c.created_at - cutoff) / week_seconds
		if idx >= 0 && idx < activity_weeks {
			buckets[idx]++
		}
	}
	return buckets
}

// get_user_daily_activity returns commit counts per day for the given user
// over the past `days` days. Index 0 is the oldest day, index `days-1` is today.
fn (app App) get_user_daily_activity(user_id int, days int) []int {
	day_seconds := 24 * 3600
	now := time.now()
	// Anchor to the start of today (local), so today is always the last bucket.
	today_start := i64(time.new(year: now.year, month: now.month, day: now.day).unix())
	cutoff := int(today_start) - (days - 1) * day_seconds
	commits := sql app.db {
		select from Commit where author_id == user_id && created_at >= cutoff
	} or { []Commit{} }
	mut buckets := []int{len: days}
	for c in commits {
		idx := (c.created_at - cutoff) / day_seconds
		if idx >= 0 && idx < days {
			buckets[idx]++
		}
	}
	return buckets
}
