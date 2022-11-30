module main

import time
import os

fn (f File) url() string {
	file_type := if f.is_dir { 'tree' } else { 'blob' }

	if f.parent_path == '' {
		return '${file_type}/${f.branch}/${f.name}'
	}

	return '${file_type}/${f.branch}/${f.parent_path}/${f.name}'
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

fn (mut app App) add_file(file File) {
	sql app.db {
		insert file into File
	}
}

fn (mut app App) find_repository_items(repo_id int, branch string, parent_path string) []File {
	valid_parent_path := if parent_path == '' { '.' } else { parent_path }

	items := sql app.db {
		select from File where repo_id == repo_id && parent_path == valid_parent_path
		&& branch == branch
	}

	return items
}

fn (mut app App) find_repo_file_by_path(repo_id int, item_branch string, path string) ?File {
	mut valid_parent_path := os.dir(path)
	item_name := path.after('/')

	if valid_parent_path == '' || valid_parent_path == '/' {
		valid_parent_path = '.'
	}

	app.info('find file repo_id=${repo_id} parent_path = ${valid_parent_path} branch=${item_branch} name=${item_branch}')

	file := sql app.db {
		select from File where repo_id == repo_id && parent_path == valid_parent_path
		&& branch == item_branch && name == item_name limit 1
	}

	if file.name == '' {
		return none
	}

	return file
}

fn (mut app App) delete_repository_files(repository_id int) {
	sql app.db {
		delete from File where repo_id == repository_id
	}
}

fn (mut app App) delete_repository_files_in_branch(repository_id int, branch_name string) {
	sql app.db {
		delete from File where repo_id == repository_id && branch == branch_name
	}
}

fn (mut app App) delete_repo_folder(path string) {
	os.rmdir_all(os.real_path(path)) or { panic(err) }
}
