// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import os

struct File {
	id              int
	repo_id         int
	name            string
	parent_path     string
	is_dir          bool
	branch          string
	nr_contributors int
	last_hash       string
	size            int
	nr_views        int
mut:
	last_msg        string
	last_time       int
	commit          Commit [skip]
}

fn (f File) url() string {
	typ := if f.is_dir { 'tree' } else { 'blob' }
	if f.parent_path == '' {
		return '$typ/$f.name'
	}
	return '$typ/$f.parent_path/$f.name'
}

fn (f &File) full_path() string {
	if f.parent_path == '' {
		return f.name
	}
	return f.parent_path + '/' + f.name
}

fn (f File) pretty_last_time() string {
	return time.unix(f.last_time).relative()
}

fn (f File) pretty_size() string {
	return 'Today'
}

fn (mut app App) insert_file(file File) {
	app.info('inserting file:')
	app.info(file.name)
	sql app.db {
		insert file into File
	}
}

fn (mut app App) find_repo_files(repo_id2 int, branch, parent_path string) []File {
	app.info('find files by repo(repo_id=$repo_id2, parent_path="$parent_path")')
	mut files := sql app.db {
		select from File where repo_id == repo_id2 && parent_path == parent_path
	}
	return files
}

fn (mut app App) find_repo_file_by_path(repo_id int, branch, path string) ?File {
	parent_path := os.base_dir(path)
	name := path.after('/')
	app.info('find file parent_path=$parent_path name=$name')
	file := sql app.db {
		select from File where repo_id == repo_id && parent_path == parent_path && name == name limit 1
	}
	if file.name == '' {
		return none
	}
	return file
}
