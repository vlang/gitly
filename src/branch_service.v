module main

import time
import git

fn (mut app App) create_branches_from_fs(repo &Repo) {
	branches_output := repo.git('branch -a')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.create_branch_if_not_exists(repo.id, branch_name)
	}
}

fn (mut app App) create_branch_if_not_exists(repository_id int, branch_name string) {
	branch := sql app.db {
		select from Branch where repo_id == repository_id && name == branch_name limit 1
	}

	if branch.id != 0 {
		return
	}

	new_branch := Branch{
		repo_id: repository_id
		name: branch_name
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

fn (mut app App) find_repo_branch_by_id(repo_id int, id int) Branch {
	return sql app.db {
		select from Branch where id == id && repo_id == repo_id limit 1
	}
}

fn (app App) get_all_repo_branches(repo_id int) []Branch {
	return sql app.db {
		select from Branch where repo_id == repo_id order by date desc
	}
}

fn (mut app App) get_count_repo_branches(repo_id int) int {
	return sql app.db {
		select count from Branch where repo_id == repo_id
	}
}

fn (mut app App) has_repo_branch(repo_id int, name string) bool {
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
