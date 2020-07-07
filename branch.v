// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time

struct Branch {
mut:
	id     int
	repo_id int
	name   string // branch name
	author string // author of latest commit on branch
	hash   string // hash of latest commit on branch
	date   int // time of latest commit on branch
}

fn (mut app App) fetch_branches(r Repo) {
	mut branch := Branch{}
	current := os.getwd()
	os.chdir(r.git_dir)
	data := r.git('branch -a')
	for remote_branch in data.split_into_lines() {
		if remote_branch.contains('remotes/') && !remote_branch.contains('HEAD') {
			temp_branch := remote_branch.trim_space().after('remotes/')
			_ := r.git('checkout -t $temp_branch')
			branch.repo_id = r.id
			branch.name = temp_branch.after('origin/')
			hash_data := os.read_lines('.git/refs/heads/$branch.name') or {
				app.info(err)
				return
			}
			branch.hash = hash_data[0].substr(0, 7)
			branch_data := r.git('log -1 --pretty="%aE$log_field_separator%cD" $branch.hash')
			args := branch_data.split(log_field_separator)
			email := args[0]
			u := app.find_user_by_email(email) or { User{username: email} }
			branch.author = u.username
			date := time.parse_rfc2822(args[1]) or {
				app.info('Error: $err')
				return
			}
			branch.date = int(date.unix)
			app.insert_branch(branch)
		}
	}
	_ := r.git('checkout master')
	os.chdir(current)
}

fn (mut app App) update_branches(r &Repo) {
	mut branch := Branch{}
	current := os.getwd()
	os.chdir(r.git_dir)
	data := r.git('branch -a')
	for remote_branch in data.split_into_lines() {
		if remote_branch.contains('remotes/') && !remote_branch.contains('HEAD') {
			temp_branch := remote_branch.trim_space().after('remotes/')
			_ := r.git('checkout -t $temp_branch')
			branch.repo_id = r.id
			branch.name = temp_branch.after('origin/')
			hash_data := os.read_lines('.git/refs/heads/$branch.name') or {
				app.info('Error: $err')
				return
			}
			branch.hash = hash_data[0].substr(0, 7)
			branch_data := r.git('log -1 --pretty="%aE$log_field_separator%cD" $branch.hash')
			args := branch_data.split(log_field_separator)
			email := args[0]
			u := app.find_user_by_email(email) or { User{username: email} }
			branch.author = u.username
			date := time.parse_rfc2822(args[1]) or {
				app.info('Error: $err')
				return
			}
			branch.date = int(date.unix)
			if !app.contains_repo_branch(branch.name, r.id) {
				app.insert_branch(branch)
			} else {
				app.update_branch(branch)
			}
		}
	}
	_ := r.git('checkout master')
	os.chdir(current)
}

fn (branch Branch) relative() string {
	return time.unix(branch.date).relative()
}

fn (mut app App) update_branch(branch Branch) {
	b := app.find_repo_branch_by_name(branch.name, branch.repo_id)
	author := branch.author
	hash := branch.hash
	date := branch.date
	sql app.db {
		update Branch set author = author, hash = hash, date = date where id == b.id
	}
}

fn (mut app App) insert_branch(branch Branch) {
		sql app.db {
		insert branch into Branch
	}
}

fn (mut app App) find_repo_branch_by_name(name string, repo_id int) Branch {
	return sql app.db {
		select from Branch where name == name && repo_id == repo_id limit 1
	}
}

fn (mut app App) find_repo_branches(repo_id int) []Branch {
	return sql app.db {
		select from Branch where repo_id == repo_id order by date desc
	}
}

fn (mut app App) nr_repo_branches(repo_id int) int {
	return sql app.db {
		select count from Branch where repo_id == repo_id
	}
}

fn (mut app App) contains_repo_branch(name string, repo_id int) bool {
	nr := sql app.db {
		select count from Branch where repo_id == repo_id && name == name
	}
	return nr == 1
}
