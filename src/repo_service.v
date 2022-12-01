// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time
import git
import highlight
import validation

// log_field_separator is declared as constant in case we need to change it later
const (
	max_git_res_size    = 1000
	log_field_separator = '\x7F'
	ignored_folder      = ['thirdparty']
)

enum RepoStatus {
	done
	caching
	clone_failed
	clone_done
}

enum ArchiveFormat {
	zip
	tar
}

fn (f ArchiveFormat) str() string {
	return match f {
		.zip { 'zip' }
		.tar { 'tar' }
	}
}

fn (mut app App) save_repo(repo Repo) {
	id := repo.id
	desc := repo.description
	views_count := repo.views_count
	webhook_secret := repo.webhook_secret
	tags_count := repo.tags_count
	is_public := if repo.is_public { 1 } else { 0 }
	open_issues_count := repo.open_issues_count
	open_prs_count := repo.open_prs_count
	branches_count := repo.branches_count
	releases_count := repo.releases_count
	stars_count := repo.stars_count
	contributors_count := repo.contributors_count

	sql app.db {
		update Repo set description = desc, views_count = views_count, is_public = is_public,
		webhook_secret = webhook_secret, tags_count = tags_count, open_issues_count = open_issues_count,
		open_prs_count = open_prs_count, releases_count = releases_count, contributors_count = contributors_count,
		stars_count = stars_count, branches_count = branches_count where id == id
	}
}

fn (app App) find_repo_by_name_and_user_id(repo_name string, user_id int) Repo {
	mut repo := sql app.db {
		select from Repo where name == repo_name && user_id == user_id limit 1
	}

	if repo.id > 0 {
		repo.lang_stats = app.find_repo_lang_stats(repo.id)
	}

	return repo
}

fn (app App) find_repo_by_name_and_username(repo_name string, username string) Repo {
	user := app.get_user_by_username(username) or { return Repo{} }

	return app.find_repo_by_name_and_user_id(repo_name, user.id)
}

fn (mut app App) get_count_user_repos(user_id int) int {
	return sql app.db {
		select count from Repo where user_id == user_id
	}
}

fn (mut app App) find_user_repos(user_id int) []Repo {
	return sql app.db {
		select from Repo where user_id == user_id
	}
}

fn (mut app App) find_user_public_repos(user_id int) []Repo {
	return sql app.db {
		select from Repo where user_id == user_id && is_public == true
	}
}

fn (app App) search_public_repos(query string) []Repo {
	repo_rows, _ := app.db.exec('select id, name, user_id, description, stars_count from `Repo` where is_public is true and name like "%${query}%"')

	mut repos := []Repo{}

	for row in repo_rows {
		user_id := row.vals[2].int()
		user := app.get_user_by_id(user_id) or { User{} }

		repos << Repo{
			id: row.vals[0].int()
			name: row.vals[1]
			user_name: user.username
			description: row.vals[3]
			stars_count: row.vals[4].int()
		}
	}

	return repos
}

fn (app App) find_repo_by_id(repo_id int) Repo {
	mut repo := sql app.db {
		select from Repo where id == repo_id
	}

	if repo.id > 0 {
		repo.lang_stats = app.find_repo_lang_stats(repo.id)
	}

	return repo
}

fn (mut app App) increment_repo_views(repo_id int) {
	sql app.db {
		update Repo set views_count = views_count + 1 where id == repo_id
	}
}

fn (mut app App) increment_repo_stars(repo_id int) {
	sql app.db {
		update Repo set stars_count = stars_count + 1 where id == repo_id
	}
}

fn (mut app App) decrement_repo_stars(repo_id int) {
	sql app.db {
		update Repo set stars_count = stars_count - 1 where id == repo_id
	}
}

fn (mut app App) increment_file_views(file_id int) {
	sql app.db {
		update File set views_count = views_count + 1 where id == file_id
	}
}

fn (mut app App) set_repo_webhook_secret(repo_id int, secret string) {
	sql app.db {
		update Repo set webhook_secret = secret where id == repo_id
	}
}

fn (mut app App) increment_repo_issues(repo_id int) {
	sql app.db {
		update Repo set open_issues_count = open_issues_count + 1 where id == repo_id
	}
}

fn (mut app App) add_repo(repo Repo) {
	sql app.db {
		insert repo into Repo
	}
}

fn (mut app App) delete_repository(id int, path string, name string) {
	sql app.db {
		delete from Repo where id == id
	}
	app.info('Removed repo entry (${id}, ${name})')

	sql app.db {
		delete from Commit where repo_id == id
	}

	app.info('Removed repo commits (${id}, ${name})')
	app.delete_repo_issues(id)
	app.info('Removed repo issues (${id}, ${name})')

	app.delete_repo_branches(id)
	app.info('Removed repo branches (${id}, ${name})')

	app.delete_repo_releases(id)
	app.info('Removed repo releases (${id}, ${name})')

	app.delete_repository_files(id)
	app.info('Removed repo files (${id}, ${name})')

	app.delete_repo_folder(path)
	app.info('Removed repo folder (${id}, ${name})')
}

fn (mut app App) move_repo_to_user(repo_id int, user_id int, user_name string) {
	sql app.db {
		update Repo set user_id = user_id, user_name = user_name where id == repo_id
	}
}

fn (mut app App) user_has_repo(user_id int, repo_name string) bool {
	count := sql app.db {
		select count from Repo where user_id == user_id && name == repo_name
	}
	return count >= 0
}

fn (mut app App) update_repo_from_fs(mut repo Repo) {
	repo_id := repo.id

	app.db.exec('BEGIN TRANSACTION')

	repo.analyse_lang(app)

	app.info(repo.contributors_count.str())
	app.fetch_branches(repo)

	branches_output := repo.git('branch -a')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.update_repo_branch_from_fs(mut repo, branch_name)
	}

	repo.contributors_count = app.get_count_repo_contributors(repo_id)
	repo.branches_count = app.get_count_repo_branches(repo_id)

	// TODO: TEMPORARY - UNTIL WE GET PERSISTENT RELEASE INFO
	for tag in app.get_all_repo_tags(repo_id) {
		app.add_release(tag.id, repo_id, time.unix(tag.created_at), tag.message)

		repo.releases_count++
	}

	app.save_repo(repo)
	app.db.exec('END TRANSACTION')
	app.info('Repo updated')
}

fn (mut app App) update_repo_branch_from_fs(mut repo Repo, branch_name string) {
	repo_id := repo.id
	branch := app.find_repo_branch_by_name(repo.id, branch_name)

	if branch.id == 0 {
		return
	}

	data := repo.git('--no-pager log ${branch_name} --abbrev-commit --abbrev=7 --pretty="%h${log_field_separator}%aE${log_field_separator}%cD${log_field_separator}%s${log_field_separator}%aN"')

	for line in data.split_into_lines() {
		args := line.split(log_field_separator)

		if args.len > 3 {
			commit_hash := args[0]
			commit_author_email := args[1]
			commit_message := args[3]
			commit_author := args[4]
			mut commit_author_id := 0

			commit_date := time.parse_rfc2822(args[2]) or {
				app.info('Error: ${err}')
				return
			}

			user := app.get_user_by_email(commit_author_email) or { User{} }

			if user.id > 0 {
				app.add_contributor(user.id, repo_id)

				commit_author_id = user.id
			}

			app.add_commit_if_not_exist(repo_id, branch.id, commit_hash, commit_author,
				commit_author_id, commit_message, int(commit_date.unix))
		}
	}
}

fn (mut app App) update_repo_from_remote(mut repo Repo) {
	repo_id := repo.id

	repo.git('fetch --all')
	repo.git('pull --all')

	app.db.exec('BEGIN TRANSACTION')

	repo.analyse_lang(app)

	app.info(repo.contributors_count.str())
	app.fetch_branches(repo)
	app.fetch_tags(repo)

	branches_output := repo.git('branch -a')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.update_repo_branch_from_fs(mut repo, branch_name)
	}

	for tag in app.get_all_repo_tags(repo_id) {
		app.add_release(tag.id, repo_id, time.unix(tag.created_at), tag.message)

		repo.releases_count++
	}

	repo.contributors_count = app.get_count_repo_contributors(repo_id)
	repo.branches_count = app.get_count_repo_branches(repo_id)

	app.save_repo(repo)
	app.db.exec('END TRANSACTION')
	app.info('Repo updated')
}

fn (mut app App) update_repo_branch_data(mut repo Repo, branch_name string) {
	repo_id := repo.id
	branch := app.find_repo_branch_by_name(repo.id, branch_name)

	if branch.id == 0 {
		return
	}

	data := repo.git('--no-pager log ${branch_name} --abbrev-commit --abbrev=7 --pretty="%h${log_field_separator}%aE${log_field_separator}%cD${log_field_separator}%s${log_field_separator}%aN"')

	for line in data.split_into_lines() {
		args := line.split(log_field_separator)

		if args.len > 3 {
			commit_hash := args[0]
			commit_author_email := args[1]
			commit_message := args[3]
			commit_author := args[4]
			mut commit_author_id := 0

			commit_date := time.parse_rfc2822(args[2]) or {
				app.info('Error: ${err}')
				return
			}

			user := app.get_user_by_email(commit_author_email) or { User{} }

			if user.id > 0 {
				app.add_contributor(user.id, repo_id)

				commit_author_id = user.id
			}

			app.add_commit_if_not_exist(repo_id, branch.id, commit_hash, commit_author,
				commit_author_id, commit_message, int(commit_date.unix))
		}
	}
}

// TODO: tags and other stuff
fn (mut app App) update_repo_after_push(repo_id int, branch_name string) {
	mut repo := app.find_repo_by_id(repo_id)

	if repo.id == 0 {
		return
	}

	app.update_repo_from_fs(mut repo)
	app.delete_repository_files_in_branch(repo_id, branch_name)
}

fn (r &Repo) analyse_lang(app &App) {
	file_paths := r.get_all_file_paths()

	mut all_size := 0
	mut lang_stats := map[string]int{}
	mut langs := map[string]highlight.Lang{}

	for file_path in file_paths {
		lang := highlight.extension_to_lang(file_path.split('.').last()) or { continue }
		file_content := r.read_file(r.primary_branch, file_path)
		lines := file_content.split_into_lines()
		size := calc_lines_of_code(lines, lang)

		if lang.name !in lang_stats {
			lang_stats[lang.name] = 0
		}
		if lang.name !in langs {
			langs[lang.name] = lang
		}

		lang_stats[lang.name] = lang_stats[lang.name] + size
		all_size += size
	}

	mut d_lang_stats := []LangStat{}
	mut tmp_a := []int{}

	for lang, amount in lang_stats {
		// skip 0 lines of code
		if amount == 0 {
			continue
		}

		mut tmp := f32(amount) / f32(all_size)
		tmp *= 1000
		pct := int(tmp)
		if pct !in tmp_a {
			tmp_a << pct
		}
		lang_data := langs[lang]
		d_lang_stats << LangStat{
			repo_id: r.id
			name: lang_data.name
			pct: pct
			color: lang_data.color
			lines_count: amount
		}
	}

	tmp_a.sort()
	tmp_a = tmp_a.reverse()

	mut tmp_stats := []LangStat{}

	for pct in tmp_a {
		all_with_ptc := r.lang_stats.filter(it.pct == pct)
		for lang in all_with_ptc {
			tmp_stats << lang
		}
	}

	app.remove_repo_lang_stats(r.id)

	for lang_stat in d_lang_stats {
		app.add_lang_stat(lang_stat)
	}
}

fn calc_lines_of_code(lines []string, lang highlight.Lang) int {
	mut size := 0
	lcomment := lang.line_comments
	mut mlcomment_start := ''
	mut mlcomment_end := ''
	if lang.mline_comments.len >= 2 {
		mlcomment_start = lang.mline_comments[0]
		mlcomment_end = lang.mline_comments[1]
	}
	mut in_comment := false
	for line in lines {
		tmp_line := line.trim_space()
		if tmp_line.len > 0 { // Empty line ignored
			if tmp_line.contains(mlcomment_start) {
				in_comment = true
				if tmp_line.starts_with(mlcomment_start) {
					continue
				}
			}
			if tmp_line.contains(mlcomment_end) {
				if in_comment {
					in_comment = false
				}
				if tmp_line.ends_with(mlcomment_end) {
					continue
				}
			}
			if in_comment {
				continue
			}
			if tmp_line.contains(lcomment) {
				if tmp_line.starts_with(lcomment) {
					continue
				}
			}
			size++
		}
	}
	return size
}

fn (r &Repo) get_all_file_paths() []string {
	ls_output := r.git('ls-tree -r ${r.primary_branch} --name-only')
	mut file_paths := []string{}

	for file_path in ls_output.split_into_lines() {
		path_parts := file_path.split('/')
		has_ignored_folders := path_parts.any(ignored_folder.contains(it))

		if has_ignored_folders {
			continue
		}

		file_paths << file_path
	}

	return file_paths
}

// TODO: return ?string
fn (r &Repo) git(command string) string {
	if command.contains('&') || command.contains(';') {
		return ''
	}

	command_with_path := '-C ${r.git_dir} ${command}'

	command_result := os.execute('git ${command_with_path}')
	command_exit_code := command_result.exit_code
	if command_exit_code != 0 {
		println('git error ${command_with_path} with ${command_exit_code} exit code out=${command_result.output}')

		return ''
	}

	return command_result.output.trim_space()
}

fn (r &Repo) parse_ls(ls_line string, branch string) ?File {
	ls_line_parts := ls_line.fields()
	if ls_line_parts.len < 4 {
		return none
	}

	item_type := ls_line_parts[1]
	item_size := ls_line_parts[3]
	item_path := ls_line_parts[4]
	item_hash := r.git('log ${branch} -n 1 --format="%h" -- ${item_path}')

	item_name := item_path.after('/')
	if item_name == '' {
		return none
	}

	mut parent_path := os.dir(item_path)
	if parent_path == item_name {
		parent_path = ''
	}

	if item_name.contains('"\\') {
		// Unqoute octal UTF-8 strings
	}

	return File{
		name: item_name
		parent_path: parent_path
		repo_id: r.id
		last_hash: item_hash
		branch: branch
		is_dir: item_type == 'tree'
		size: if item_type == 'blob' { item_size.int() } else { 0 }
	}
}

// Fetches all files via `git ls-tree` and saves them in db
fn (mut app App) cache_repository_items(mut r Repo, branch string, path string) []File {
	if r.status == .caching {
		app.info('`${r.name}` is being cached already')
		return []
	}

	mut repository_ls := ''
	if path == '.' {
		r.status = .caching

		defer {
			r.status = .done
		}
	} else {
		directory_path := if path == '' { path } else { '${path}/' }
		format := '%(objectmode) %(objecttype) %(objectname) %(objectsize) %(path)'
		repository_ls = r.git('ls-tree --full-name --format="${format}" ${branch} ${directory_path}')
	}

	// mode type name path
	item_info_lines := repository_ls.split('\n')

	mut dirs := []File{} // dirs first
	mut files := []File{}

	app.db.exec('BEGIN TRANSACTION')

	for item_info in item_info_lines {
		is_item_info_empty := validation.is_string_empty(item_info)

		if is_item_info_empty {
			continue
		}

		file := r.parse_ls(item_info, branch) or {
			app.warn('failed to parse ${item_info}')
			continue
		}

		if file.is_dir {
			dirs << file

			app.add_file(file)
		} else {
			files << file
		}
	}

	dirs << files
	for file in files {
		app.add_file(file)
	}

	app.db.exec('END TRANSACTION')

	return dirs
}

// fetches last message and last time for each file
// this is slow, so it's run in the background thread
fn (mut app App) slow_fetch_files_info(mut repo Repo, branch string, path string) {
	files := app.find_repository_items(repo.id, branch, path)

	for i in 0 .. files.len {
		if files[i].last_msg != '' {
			app.warn('skipping ${files[i].name}')
			continue
		}

		app.fetch_file_info(repo, files[i])
	}
}

fn (r Repo) get_last_branch_commit_hash(branch_name string) string {
	git_result := os.execute('git -C ${r.git_dir} log -n 1 ${branch_name} --pretty=format:"%h"')
	git_output := git_result.output

	if git_result.exit_code != 0 {
		eprintln('git log error: ${git_output}')
	}

	return git_output
}

fn (r Repo) git_advertise(service string) string {
	git_result := os.execute('git ${service} --stateless-rpc --advertise-refs ${r.git_dir}')
	git_output := git_result.output

	if git_result.exit_code != 0 {
		eprintln('git ${service} error: ${git_output}')
	}

	return git_output
}

fn (r Repo) archive_tag(tag string, path string, format ArchiveFormat) {
	// TODO: check tag name before running command
	r.git('archive ${tag} --format=${format} --output="${path}"')
}

fn (r Repo) get_commit_patch(commit_hash string) ?string {
	patch := r.git('format-patch --stdout -1 ${commit_hash}')

	if patch == '' {
		return none
	}

	return patch
}

fn (r Repo) git_smart(service string, input string) string {
	git_path := git.get_git_executable_path() or { 'git' }
	real_repository_path := os.real_path(r.git_dir)

	mut process := os.new_process(git_path)
	process.set_args([service, '--stateless-rpc', real_repository_path])

	process.set_redirect_stdio()
	process.run()
	process.stdin_write(input)
	process.stdin_write('\n')

	output := process.stdout_slurp()
	errors := process.stderr_slurp()

	process.wait()
	process.close()

	if errors.len > 0 {
		eprintln('git ${service} error: ${errors}')

		return ''
	}

	return output
}

fn (mut app App) generate_clone_url(repo Repo) string {
	hostname := app.config.hostname
	username := repo.user_name
	repo_name := repo.name

	return 'https://${hostname}/${username}/${repo_name}.git'
}

fn first_line(s string) string {
	pos := s.index('\n') or { return s }
	return s[..pos]
}

fn (mut app App) fetch_file_info(r &Repo, file &File) {
	logs := r.git('log -n1 --format=%B___%at___%H___%an ${file.branch} -- ${file.full_path()}')
	vals := logs.split('___')
	if vals.len < 3 {
		return
	}
	last_msg := first_line(vals[0])
	last_time := vals[1].int() // last_hash

	file_id := file.id
	sql app.db {
		update File set last_msg = last_msg, last_time = last_time where id == file_id
	}
}

fn (mut app App) update_repo_primary_branch(repo_id int, branch string) {
	sql app.db {
		update Repo set primary_branch = branch where id == repo_id
	}
}

fn (mut r Repo) clone() {
	clone_result := os.execute('git clone --bare "${r.clone_url}" ${r.git_dir}')
	close_exit_code := clone_result.exit_code

	if close_exit_code != 0 {
		r.status = .clone_failed
		println('git clone failed with exit code ${close_exit_code}')
		return
	}

	r.status = .clone_done
}

fn (r &Repo) read_file(branch string, path string) string {
	valid_path := path.trim_string_left('/')

	return r.git('--no-pager show ${branch}:${valid_path}')
}

fn find_readme_file(items []File) ?File {
	files := items.filter(it.name.to_lower().starts_with('readme.') && it.name.split('.').len == 2
		&& !it.is_dir)

	if files.len == 0 {
		return none
	}

	// firstly search markdown files
	readme_md_files := files.filter(it.name.to_lower().ends_with('.md'))

	if readme_md_files.len > 0 {
		return readme_md_files.first()
	}

	// and then txt files
	readme_txt_files := files.filter(it.name.to_lower().ends_with('.txt'))

	if readme_txt_files.len > 0 {
		return readme_txt_files.first()
	}

	return none
}

fn find_license_file(items []File) ?File {
	files := items.filter(it.name.to_lower() == 'license')

	if files.len == 0 {
		return none
	}

	return files[0]
}

fn (app App) has_user_repo_read_access(user_id int, repo_id int) bool {
	if !app.logged_in {
		return false
	}

	repo := app.find_repo_by_id(repo_id)

	if repo.id == 0 {
		return false
	}

	if repo.is_public {
		return true
	}

	is_repo_owner := repo.user_id == user_id

	if is_repo_owner {
		return true
	}

	return false
}

fn (app App) has_user_repo_read_access_by_repo_name(user_id int, repo_owner_name string, repo_name string) bool {
	user := app.get_user_by_username(repo_owner_name) or { return false }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id)

	return app.has_user_repo_read_access(user_id, repo.id)
}

fn (app App) check_repo_owner(username string, repo_name string) bool {
	user := app.get_user_by_username(username) or { return false }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id)

	return repo.user_id == user.id
}
