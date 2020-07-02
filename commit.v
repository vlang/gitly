// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Commit {
mut:
	id         int
	author_id  int
	author     string
	hash       string
	created_at int
	repo_id    int
	message    string
}

struct Change {
mut:
	file      string
	additions int
	deletions int
	diff      string
	message   string
}

fn (commit Commit) relative() string {
	return time.unix(commit.created_at).relative()
}

fn (commit Commit) get_changes(repo Repo) []Change {
	changes_s := repo.git('show $commit.hash')
	mut tmp_change := Change{}
	mut changes := []Change{}
	mut started := false
	for line in changes_s.split_into_lines() {
		args := line.split(' ')
		if args.len <= 0 {
			continue
		}
		match args[0] {
			'diff' {
				started = true
				if tmp_change.file.len > 0 {
					changes << tmp_change
					tmp_change = Change{}
				}
				tmp_change.file = args[2][2..]
			}
			'index' {
				continue
			}
			'---' {
				continue
			}
			'+++' {
				continue
			}
			'@@' {
				tmp_change.diff = line
			}
			else {
				if started {
					if line.bytes()[0] == `+` {
						tmp_change.additions++
					}
					if line.bytes()[0] == `-` {
						tmp_change.deletions++
					}
					tmp_change.message += '$line\n'
				}
			}
		}
	}
	changes << tmp_change
	return changes
}

fn (mut app App) insert_commit(commit Commit) {
	sql app.db {
		insert commit into Commit
	}
}

fn (mut app App) find_commits_by_repo(repo_id int) []Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id limit 10 
	}
}

fn (mut app App) find_commits_by_repo_as_page(repo_id, page int) []Commit {
	offs := page * commits_per_page
	return sql app.db {
		select from Commit where repo_id == repo_id order by created_at desc limit 35 offset offs
	}
}

fn (mut app App) commits_by_repo_id_size(repo_id int) int {
	return sql app.db {
		select count from Commit where repo_id == repo_id 
	}
}

fn (mut app App) find_commit_by_hash(repo_id int, hash string) Commit {
	commits := sql app.db {
		select from Commit where repo_id == repo_id && hash == hash 
	}
	if commits.len == 1 {
		return commits[0]
	}
	return Commit{}
}

fn (mut app App) find_last_commit(repo_id int) Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id order by created_at desc limit 1
	}
}

fn (mut app App) first_commit_by_repo_id(repo_id int) Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id order by created_at limit 1
	}
}

fn (mut app App) find_commits_by_author(repo_id int, author string) []Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id && author == author limit 10 
	}
}
