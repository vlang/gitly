// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

fn (commit Commit) relative() string {
	return time.unix(commit.created_at).relative()
}

fn (mut app App) create_commits_from_fs(mut repo Repo, branch_name string) ! {
	repo_id := repo.id
	branch := app.find_repo_branch_by_name(repo.id, branch_name)

	if branch.id == 0 {
		return
	}

	last_commit_hash := app.get_last_branch_commit_hash(repo_id, branch_name)
	commit_range := if last_commit_hash == '' { '' } else { '${last_commit_hash}..HEAD' }

	data := repo.git('--no-pager log ${branch_name} --abbrev-commit --abbrev=7 --pretty="%h${log_field_separator}%aE${log_field_separator}%ct${log_field_separator}%s${log_field_separator}%aN" ${commit_range}')
	commit_lines := data.split_into_lines()

	if commit_lines.len > 0 {
		last_commit := commit_lines.first()
		commit_parts := last_commit.split(log_field_separator)
		branch_author := commit_parts[4]
		branch_hash := commit_parts[0]
		branch_date := commit_parts[2].int()

		app.update_branch(branch.id, branch_author, branch_hash, branch_date)
	}

	for line in commit_lines {
		args := line.split(log_field_separator)

		if args.len > 3 {
			commit_hash := args[0]
			commit_author_email := args[1]
			commit_message := args[3]
			commit_author := args[4]
			mut commit_author_id := 0
			commit_date := time.unix(args[2].int())

			user := app.get_user_by_email(commit_author_email) or { User{} }

			if user.id > 0 {
				app.add_contributor(user.id, repo_id)

				commit_author_id = user.id
			}

			app.add_commit(repo_id, branch.id, commit_hash, commit_author, commit_author_id,
				commit_message, int(commit_date.unix))!
		}
	}
}

fn (commit Commit) get_changes(repo Repo) []Change {
	git_changes := repo.git('show ${commit.hash}')

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
					change.message += '${line}\n'
				}
			}
		}
	}

	changes << change

	return changes
}

fn (mut app App) add_commit(repo_id int, branch_id int, last_hash string, author string, author_id int, message string, date int) ! {
	commit := sql app.db {
		select from Commit where repo_id == repo_id && branch_id == branch_id && hash == last_hash limit 1
	}

	if commit.id > 0 {
		return error('A commit with hash ${last_hash} already exists')
	}

	new_commit := Commit{
		author_id: author_id
		author: author
		hash: last_hash
		created_at: date
		repo_id: repo_id
		branch_id: branch_id
		message: message
	}

	sql app.db {
		insert new_commit into Commit
	}
}

fn (mut app App) find_repo_commits_as_page(repo_id int, branch_id int, offset int) []Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id && branch_id == branch_id order by created_at desc limit 35 offset offset
	}
}

fn (mut app App) get_repo_commit_count(repo_id int, branch_id int) int {
	return sql app.db {
		select count from Commit where repo_id == repo_id && branch_id == branch_id
	}
}

fn (app &App) find_repo_commit_by_hash(repo_id int, branch_id int, hash string) Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id && branch_id == branch_id && hash == hash limit 1
	}
}

fn (app &App) find_repo_last_commit(repo_id int, branch_id int) Commit {
	return sql app.db {
		select from Commit where repo_id == repo_id && branch_id == branch_id order by created_at desc limit 1
	}
}

fn (app &App) get_last_commit_for_path(repo_id int, branch &Branch, item_path string) Commit {
	mut last_commit := Commit{}
	can_up := item_path != ''

	if can_up {
		mut path := item_path
		if path.ends_with('/') {
			path = path[0..item_path.len - 1]
		}

		if !path.contains('/') {
			path = '/${path}'
		}

		if dir := app.get_repo_file_by_path(repo_id, branch.name, path) {
			last_commit = app.find_repo_commit_by_hash(repo_id, branch.id, dir.last_hash)
		}
	} else {
		last_commit = app.find_repo_last_commit(repo_id, branch.id)
	}

	return last_commit
}
