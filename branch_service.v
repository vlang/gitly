module main

import os
import time

fn (mut app App) fetch_branches(r Repo) {
	all_branches := r.git('branch -a')

	for remote_branch in all_branches.split_into_lines() {
		if remote_branch.contains('remotes/') && !remote_branch.contains('HEAD') {
			temp_branch := remote_branch.trim_space().after('remotes/')

			r.git('checkout -t $temp_branch')

			branch_name := temp_branch.after('origin/')

			hash_data := os.read_lines('$r.git_dir/.git/refs/heads/$branch_name') or {
				app.info(err.msg())
				return
			}

			last_commit_hash := hash_data[0].substr(0, 7)

			branch_data := r.git('log -1 --pretty="%aE$log_field_separator%cD" $last_commit_hash')

			args := branch_data.split(log_field_separator)
			email := args[0]

			user := app.find_user_by_email(email) or {
				User{
					username: email
				}
			}

			date := time.parse_rfc2822(args[1]) or {
				app.info('Error: $err')

				return
			}

			app.create_branch(r.id, branch_name, user.username, last_commit_hash, int(date.unix))
		}
	}

	r.git('checkout $r.primary_branch')
}

fn (mut app App) update_branches(r &Repo) {
	all_branches := r.git('branch -a')

	for remote_branch in all_branches.split_into_lines() {
		if remote_branch.contains('remotes/') && !remote_branch.contains('HEAD') {
			temp_branch := remote_branch.trim_space().after('remotes/')

			r.git('checkout -t $temp_branch')

			branch_name := temp_branch.after('origin/')

			hash_data := os.read_lines('$r.git_dir/.git/refs/heads/$branch_name') or {
				app.info('Error: $err')
				return
			}

			last_commit_hash := hash_data[0].substr(0, 7)
			branch_data := r.git('log -1 --pretty="%aE$log_field_separator%cD" $last_commit_hash')

			args := branch_data.split(log_field_separator)
			email := args[0]

			user := app.find_user_by_email(email) or {
				User{
					username: email
				}
			}

			date := time.parse_rfc2822(args[1]) or {
				app.info('Error: $err')

				return
			}

			if !app.contains_repo_branch(r.id, branch_name) {
				app.create_branch(r.id, branch_name, user.username, last_commit_hash,
					int(date.unix))
			} else {
				branch := app.find_repo_branch_by_name(r.id, branch_name)

				app.update_branch(branch.id, user.username, last_commit_hash, int(date.unix))
			}
		}
	}

	r.git('checkout $r.primary_branch')
}

fn (mut app App) create_branch(repo_id int, name string, author string, hash string, date int) {
	branch := Branch{
		repo_id: repo_id
		name: name
		author: author
		hash: hash
		date: date
	}

	sql app.db {
		insert branch into Branch
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
