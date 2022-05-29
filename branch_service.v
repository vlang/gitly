module main

import time
import git

fn (mut app App) fetch_branch(repo Repo, branch_name string) {
	last_commit_hash := repo.get_last_branch_commit_hash(branch_name)

	branch_data := repo.git('log $branch_name -1 --pretty="%aE$log_field_separator%cD" $last_commit_hash')
	log_parts := branch_data.split(log_field_separator)

	author_email := log_parts[0]
	committed_at := time.parse_rfc2822(log_parts[1]) or {
		app.info('Error: $err')

		return
	}

	user := app.find_user_by_email(author_email) or {
		User{
			username: author_email
		}
	}

	app.create_branch_or_update(repo.id, branch_name, user.username, last_commit_hash,
		int(committed_at.unix))
}

fn (mut app App) fetch_branches(repo Repo) {
	branches_output := repo.git('branch -a')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.fetch_branch(repo, branch_name)
	}
}

fn (mut app App) create_branch_or_update(repository_id int, branch_name string, author string, hash string, date int) {
	branch := sql app.db {
		select from Branch where repo_id == repository_id && name == branch_name limit 1
	}

	if branch.id != 0 {
		app.update_branch(branch.id, author, hash, date)

		return
	}

	new_branch := Branch{
		repo_id: repository_id
		name: branch_name
		author: author
		hash: hash
		date: date
	}

	sql app.db {
		insert new_branch into Branch
	}
}

fn (mut app App) update_branch(branch_id int, author string, hash string, date int) {
	sql app.db {
		update Branch set author = author, hash = hash, date = date where id == branch_id
	}
}

fn (mut app App) find_repo_branch_by_name(repo_id int, name string) Branch {
	return sql app.db {
		select from Branch where name == name && repo_id == repo_id limit 1
	}
}

fn (mut app App) get_all_repo_branches(repo_id int) []Branch {
	return sql app.db {
		select from Branch where repo_id == repo_id order by date desc
	}
}

fn (mut app App) get_count_repo_branches(repo_id int) int {
	return sql app.db {
		select count from Branch where repo_id == repo_id
	}
}

fn (mut app App) contains_repo_branch(repo_id int, name string) bool {
	count := sql app.db {
		select count from Branch where repo_id == repo_id && name == name
	}

	return count == 1
}

fn (mut app App) delete_repo_branches(repo_id int) {
	sql app.db {
		delete from Branch where repo_id == repo_id
	}
}

fn (branch Branch) relative() string {
	return time.unix(branch.date).relative()
}
