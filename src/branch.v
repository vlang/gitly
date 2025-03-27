module main

import time
import git

struct Branch {
mut:
	id      int    @[primary; sql: serial]
	repo_id int    @[unique: 'branch']
	name    string @[unique: 'branch']
	author  string // author of latest commit on branch
	hash    string // hash of latest commit on branch
	date    int    // time of latest commit on branch
}

fn (mut app App) fetch_branches(repo Repo) ! {
	branches_output := repo.git('branch -a')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.fetch_branch(repo, branch_name)!
	}
}

fn (mut app App) fetch_branch(repo Repo, branch_name string) ! {
	last_commit_hash := repo.get_last_branch_commit_hash(branch_name)

	branch_data := repo.git('log ${branch_name} -1 --pretty="%aE${log_field_separator}%cD" ${last_commit_hash}')
	log_parts := branch_data.split(log_field_separator)

	author_email := log_parts[0]
	committed_at := time.parse_rfc2822(log_parts[1]) or {
		app.info('Error: ${err}')

		return
	}

	user := app.get_user_by_email(author_email) or {
		User{
			username: author_email
		}
	}

	app.create_branch_or_update(repo.id, branch_name, user.username, last_commit_hash,
		int(committed_at.unix()))!
}

fn (mut app App) create_branch_or_update(repository_id int, branch_name string, author string, hash string, date int) ! {
	branches := sql app.db {
		select from Branch where repo_id == repository_id && name == branch_name limit 1
	} or { []Branch{} }

	// app.debug("branches: ${branches}")

	if branches.len != 0 {
		branch := branches.first()
		app.update_branch(branch.id, author, hash, date)!

		return
	}

	new_branch := Branch{
		repo_id: repository_id
		name:    branch_name
		author:  author
		hash:    hash
		date:    date
	}

	app.debug("inserting branch: ${new_branch}")

	sql app.db {
		insert new_branch into Branch
	}!
}

fn (mut app App) update_branch(branch_id int, author_ string, hash_ string, date_ int) ! {
	sql app.db {
		update Branch set author = author_, hash = hash_, date = date_ where id == branch_id
	}!
}

fn (mut app App) find_repo_branch_by_name(repo_id int, name string) Branch {
	branches := sql app.db {
		select from Branch where name == name && repo_id == repo_id limit 1
	} or { []Branch{} }

	if branches.len == 0 {
		return Branch{}
	}

	return branches.first()
}

fn (mut app App) find_repo_branch_by_id(repo_id int, id int) Branch {
	branches := sql app.db {
		select from Branch where id == id && repo_id == repo_id limit 1
	} or { []Branch{} }

	if branches.len == 0 {
		return Branch{}
	}

	return branches.first()
}

fn (app App) get_all_repo_branches(repo_id int) []Branch {
	return sql app.db {
		select from Branch where repo_id == repo_id order by date desc
	} or { []Branch{} }
}

fn (mut app App) get_count_repo_branches(repo_id int) int {
	return sql app.db {
		select count from Branch where repo_id == repo_id
	} or { 0 }
}

fn (mut app App) contains_repo_branch(repo_id int, name string) bool {
	count := sql app.db {
		select count from Branch where repo_id == repo_id && name == name
	} or { 0 }

	return count == 1
}

fn (mut app App) delete_repo_branches(repo_id int) ! {
	sql app.db {
		delete from Branch where repo_id == repo_id
	}!
}

fn (branch Branch) relative() string {
	return time.unix(branch.date).relative()
}
