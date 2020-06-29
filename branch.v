// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time

struct Branch {
mut:
	name   string // branch name
	author string // author of latest commit on branch
	hash   string // hash of latest commit on branch
	date   time.Time // time of latest commit on branch
}

fn get_branches(r Repo) []Branch {
	mut branches := []Branch{}
	mut branch := Branch{}
	current := os.getwd()
	os.chdir(r.git_dir)
	data := r.git('branch -a')
	for remote_branch in data.split_into_lines() {
		if remote_branch.contains('remotes/') && !remote_branch.contains('HEAD') {
			temp_branch := remote_branch.trim_space().after('remotes/')
			_ := r.git('checkout -t $temp_branch')
			branch.name = temp_branch.after('origin/')
			hash_data := os.read_lines('.git/refs/heads/$branch.name') or {
				eprintln('Error: $err')
				return branches
			}
			branch.hash = hash_data[0].substr(0, 7)
			branch_data := r.git('log -1 --pretty="%aE$log_field_separator%cD" $branch.hash')
			args := branch_data.split(log_field_separator)
			branch.author = args[0]
			branch.date = time.parse_rfc2822(args[1]) or {
				eprintln('Error: $err')
				return branches
			}
			branches << branch
		}
	}
	branches.sort_with_compare(compare_time)
	_ := r.git('checkout master')
	os.chdir(current)
	return branches
}

fn compare_time(a, b &Branch) int {
	if a.date.gt(b.date) {
		return -1
	}
	if a.date.lt(b.date) {
		return 1
	}
	return 0
}
