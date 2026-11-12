module main

import time
import math
import os
import net.urllib

struct File {
	id                 int    @[primary; sql: serial]
	repo_id            int    @[unique: 'file']
	name               string @[unique: 'file']
	parent_path        string @[unique: 'file']
	is_dir             bool
	branch             string @[unique: 'file']
	contributors_count int
	last_hash          string
	size               int
	is_size_calculated bool
	views_count        int
mut:
	last_msg  string
	last_time int
	commit    Commit @[skip]
}

fn (f File) url() string {
	file_type := if f.is_dir { 'tree' } else { 'blob' }
	return '${file_type}/${repo_url_path(f.branch)}/${repo_url_path(f.full_path())}'
}

// repo_url_path percent-encodes each Git path component while preserving `/`
// as the route separator. Repository filenames may legally contain spaces,
// `#`, `?`, and `%`; interpolating them raw changes the URL's meaning.
fn repo_url_path(value string) string {
	return value.split('/').map(urllib.path_escape(it)).join('/')
}

fn (f &File) full_path() string {
	if f.parent_path == '' || f.parent_path == '.' {
		return f.name
	}

	return f.parent_path + '/' + f.name
}

fn (f File) pretty_last_time() string {
	if f.last_time == 0 {
		return ''
	}
	return time.unix(f.last_time).relative()
}

fn (f File) pretty_size() string {
	if f.size == 0 {
		return 'n/a'
	}

	return pretty_size_bytes(f.size)
}

fn (f File) pretty_tree_size() string {
	if !f.is_dir || !f.is_size_calculated {
		return ''
	}

	return pretty_size_bytes(f.size)
}

fn pretty_size_bytes(size_in_bytes int) string {
	sizes := ['bytes', 'KB', 'MB', 'GB', 'TB']

	if size_in_bytes == 0 {
		return '0 bytes'
	}

	index := int(math.floor(math.log(size_in_bytes) / math.log(1024)))

	if index == 0 {
		return '${size_in_bytes} ${sizes[index]}'
	}

	size_in := math.round_sig(size_in_bytes / (math.pow(1024, index)), 2)

	return '${size_in} ${sizes[index]}'
}

// Named `RepoFileInfo` rather than `FileInfo` to avoid colliding with
// `os.FileInfo`, which V resolves in the wrong scope when this type is
// substituted into the `api.ApiSuccessResponse[T]` generic.
struct RepoFileInfo {
	name      string
	last_msg  string
	last_hash string
	last_time string
	size      string
}

fn calculate_lines_of_code(source string) (int, int) {
	lines := source.split_into_lines()
	loc := lines.len
	sloc := lines.filter(it.trim_space() != '').len

	return loc, sloc
}

fn (mut app App) add_file(file File) ! {
	sql app.db {
		insert file into File
	}!
}

fn (mut app App) find_repository_items(repo_id int, branch string, parent_path string) []File {
	valid_parent_path := if parent_path == '' { '.' } else { parent_path }

	items := sql app.db {
		select from File where repo_id == repo_id && parent_path == valid_parent_path
		&& branch == branch
	} or { []File{} }

	return items
}

fn (mut app App) find_repo_file_by_path(repo_id int, item_branch string, path string) ?File {
	normalized_path := path.trim_string_left('/')
	mut valid_parent_path := os.dir(normalized_path)
	item_name := os.base(normalized_path)

	if valid_parent_path == '' || valid_parent_path == '/' || valid_parent_path == normalized_path {
		valid_parent_path = '.'
	}

	app.info('find file repo_id=${repo_id} parent_path=${valid_parent_path} branch=${item_branch} name=${item_name}')

	files := sql app.db {
		select from File where repo_id == repo_id && parent_path == valid_parent_path
		&& branch == item_branch && name == item_name limit 1
	} or { []File{} }

	if files.len == 0 {
		return none
	}

	return files.first()
}

fn (mut app App) delete_repository_files(repository_id int) ! {
	sql app.db {
		delete from File where repo_id == repository_id
	}!
}

fn (mut app App) delete_repository_files_in_branch(repository_id int, branch_name string) ! {
	sql app.db {
		delete from File where repo_id == repository_id && branch == branch_name
	}!
}

fn (mut app App) delete_repo_folder(path string) {
	if path == '' {
		return
	}
	storage_root := os.real_path(app.config.repo_storage_path).trim_right(os.path_separator)
	target := os.real_path(path).trim_right(os.path_separator)
	prefix := storage_root + os.path_separator
	if target == storage_root || !target.starts_with(prefix) {
		app.warn('refusing to remove repository path outside storage root: ${path}')
		return
	}
	relative := target[prefix.len..]
	if relative.split(os.path_separator).len < 2 {
		app.warn('refusing to remove repository owner directory: ${path}')
		return
	}
	os.rmdir_all(target) or { app.warn('failed to remove repo folder ${path}: ${err}') }
}
