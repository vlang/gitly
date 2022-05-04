// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

fn (commit Commit) relative() string {
	return time.unix(commit.created_at).relative()
}

fn (commit Commit) get_changes(repo Repo) []Change {
	git_changes := repo.git('show $commit.hash')

	mut change := Change{}
	mut changes := []Change{}
	mut started := false
	for line in git_changes.split_into_lines() {
		args := line.split(' ')
		if args.len <= 0 {
			continue
		}

		match args[0] {
			'diff' {
				started = true
				if change.file.len > 0 {
					changes << change
					change = Change{}
				}
				change.file = args[2][2..]
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
				change.diff = line
			}
			else {
				if started {
					if line.bytes()[0] == `+` {
						change.additions++
					}
					if line.bytes()[0] == `-` {
						change.deletions++
					}
					change.message += '$line\n'
				}
			}
		}
	}

	changes << change

	return changes
}

fn (mut app App) add_commit(repo_id int, hash string, author string, author_id int, message string, date int) {
	commit := Commit{
		author_id: author_id
		author: author
		hash: hash
		created_at: date
		repo_id: repo_id
		message: message
	}

	sql app.db {
		insert commit into Commit
	}
}

fn (mut app App) get_last_repo_commits(repo_id int) []Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id limit 10
	}
}

fn (mut app App) find_repo_commits_as_page(repo_id int, page int) []Commit {
	offs := page * commits_per_page

	return sql app.db {
		select from Commit where repo_id == repo_id order by created_at desc limit 35 offset offs
	}
}

fn (mut app App) get_count_repo_commits(repo_id int) int {
	return sql app.db {
		select count from Commit where repo_id == repo_id
	}
}

fn (mut app App) find_repo_commit_by_hash(repo_id int, hash string) Commit {
	commits := sql app.db {
		select from Commit where repo_id == repo_id && hash == hash
	}
	if commits.len == 1 {
		return commits[0]
	}
	return Commit{}
}

fn (mut app App) find_repo_last_commit(repo_id int) Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id order by created_at desc limit 1
	}
}
