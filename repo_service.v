// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
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

fn (mut app App) update_repo_in_db(repo &Repo) {
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
	contributors_count := repo.contributors_count
	commits_count := repo.commits_count
	sql app.db {
		update Repo set description = desc, views_count = views_count, is_public = is_public,
		webhook_secret = webhook_secret, tags_count = tags_count, open_issues_count = open_issues_count,
		open_prs_count = open_prs_count, releases_count = releases_count, contributors_count = contributors_count,
		commits_count = commits_count, branches_count = branches_count where id == id
	}
}

fn (mut app App) find_repo_by_name(user int, name string) ?Repo {
	x := sql app.db {
		select from Repo where name == name && user_id == user limit 1
	}
	if x.id == 0 {
		return none
	}
	return x
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

fn (mut app App) get_count_user_public_repos(user_id int) int {
	return sql app.db {
		select count from Repo where user_id == user_id && is_public == true
	}
}

fn (mut app App) find_user_public_repos(user_id int) []Repo {
	return sql app.db {
		select from Repo where user_id == user_id && is_public == true
	}
}

fn (mut app App) find_repo_by_id(repo_id int) Repo {
	return sql app.db {
		select from Repo where id == repo_id
	}
}

fn (mut app App) exists_user_repo(username string, name string) bool {
	if username.len == 0 || name.len == 0 {
		return false
	}

	user := app.find_user_by_username(username) or { return false }

	app.repo = app.find_repo_by_name(user.id, name) or { return false }

	app.repo.lang_stats = app.find_repo_lang_stats(app.repo.id)
	app.html_path = app.repo.html_path_to(app.current_path, app.repo.primary_branch)

	return true
}

fn (mut app App) increment_repo_views(repo_id int) {
	sql app.db {
		update Repo set views_count = views_count + 1 where id == repo_id
	}
}

fn (mut app App) increment_file_views(file_id int) {
	sql app.db {
		update File set views_count = views_count + 1 where id == file_id
	}
}

fn (mut app App) increment_repo_issues(repo_id int) {
	sql app.db {
		update Repo set open_issues_count = open_issues_count + 1 where id == repo_id
	}

	app.repo.open_issues_count++
}

fn (mut app App) update_repo_commits_count(repo_id int, commits_count int) {
	sql app.db {
		update Repo set commits_count = commits_count where id == repo_id
	}

	app.repo.commits_count = commits_count
}

fn (mut app App) update_repo_webhook(repo_id int, webhook string) {
	sql app.db {
		update Repo set webhook_secret = webhook where id == repo_id
	}
}

fn (mut app App) update_repo_contributors_count(repo_id int, contributors_count int) {
	sql app.db {
		update Repo set contributors_count = contributors_count where id == repo_id
	}
	app.repo.contributors_count = contributors_count
}

fn (mut app App) add_repo(repo Repo) {
	sql app.db {
		insert repo into Repo
	}
}

fn (mut app App) delete_repo(id int, path string, name string) {
	sql app.db {
		delete from Repo where id == id
	}
	app.info('Removed repo entry ($id, $name)')

	sql app.db {
		delete from Commit where repo_id == id
	}

	app.info('Removed repo commits ($id, $name)')
	app.delete_repo_issues(id)
	app.info('Removed repo issues ($id, $name)')

	app.delete_repo_branches(id)
	app.info('Removed repo branches ($id, $name)')

	app.delete_repo_releases(id)
	app.info('Removed repo releases ($id, $name)')

	app.delete_repo_files(id)
	app.info('Removed repo files ($id, $name)')

	app.delete_repo_folder(path)
	app.info('Removed repo folder ($id, $name)')
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

fn (mut app App) update_repository() {
	mut r := app.repo

	r.analyse_lang(app)

	data := r.git('--no-pager log --abbrev-commit --abbrev=7 --pretty="%h$log_field_separator%aE$log_field_separator%cD$log_field_separator%s$log_field_separator%aN"')
	app.db.exec('BEGIN TRANSACTION')

	for line in data.split_into_lines() {
		args := line.split(log_field_separator)
		if args.len > 3 {
			repo_id := r.id
			commit_hash := args[0]
			commit_message := args[3]
			commit_author := args[4]
			mut commit_author_id := 0

			commit_date := time.parse_rfc2822(args[2]) or {
				app.info('Error: $err')
				return
			}

			user := app.find_user_by_email(args[1]) or { User{} }
			if user.username != '' {
				app.add_contributor(user.id, r.id)

				commit_author_id = user.id
			} else {
				empty_user := app.create_empty_user(commit_author, args[1])

				app.add_contributor(empty_user, r.id)
			}

			app.add_commit(repo_id, commit_hash, commit_author, commit_author_id, commit_message,
				int(commit_date.unix))
		}
	}

	app.info(r.contributors_count.str())
	app.fetch_branches(r)

	r.commits_count = app.get_count_repo_commits(r.id)
	r.contributors_count = app.get_count_repo_contributors(r.id)
	r.branches_count = app.get_count_repo_branches(r.id)

	app.update_repo_commits_count(r.id, r.commits_count)
	app.update_repo_contributors_count(r.id, r.contributors_count)

	// TODO: TEMPORARY - UNTIL WE GET PERSISTENT RELEASE INFO
	for tag in app.get_all_repo_tags(r.id) {
		app.add_release(tag.id, r.id)

		r.releases_count++
	}

	app.update_repo_in_db(r)
	app.db.exec('END TRANSACTION')
	app.info('Repository updated')
}

fn (mut app App) update_repo_data(mut r Repo) {
	r.git('fetch --all')
	r.git('pull --all')

	r.analyse_lang(app)

	data := r.git('--no-pager log --abbrev-commit --abbrev=7 --pretty="%h$log_field_separator%aE$log_field_separator%cD$log_field_separator%s$log_field_separator%aN"')

	app.db.exec('BEGIN TRANSACTION')

	for line in data.split_into_lines() {
		args := line.split(log_field_separator)
		if args.len > 3 {
			repo_id := r.id
			commit_hash := args[0]
			commit_message := args[3]
			commit_author := args[4]
			mut commit_author_id := 0

			commit_date := time.parse_rfc2822(args[2]) or {
				app.info('Error: $err')
				return
			}

			user := app.find_user_by_email(args[1]) or { User{} }

			if user.username != '' {
				app.add_contributor(user.id, r.id)

				commit_author_id = user.id
			} else {
				empty_user := app.create_empty_user(commit_author, args[1])

				app.add_contributor(empty_user, r.id)
			}

			app.add_commit(repo_id, commit_hash, commit_author, commit_author_id, commit_message,
				int(commit_date.unix))
		}
	}

	r.commits_count = app.get_count_repo_commits(r.id)
	r.contributors_count = app.get_count_repo_contributors(r.id)
	r.branches_count = app.get_count_repo_branches(r.id)

	app.update_repo_commits_count(r.id, r.commits_count)
	app.update_repo_contributors_count(r.id, r.contributors_count)
	app.update_branches(r)
	app.update_repo_in_db(r)

	app.db.exec('END TRANSACTION')
	app.info('Repo updated')
}

fn (r &Repo) analyse_lang(app &App) {
	files := r.get_all_files(r.git_dir)
	mut all_size := 0
	mut lang_stats := map[string]int{}
	mut langs := map[string]highlight.Lang{}
	for file in files {
		lang := highlight.extension_to_lang(file.split('.').last()) or { continue }
		f_text := os.read_file(file) or { '' }
		lines := f_text.split_into_lines()
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
	for lang_stat in d_lang_stats {
		sql app.db {
			insert lang_stat into LangStat
		}
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

fn (r &Repo) get_all_files(path string) []string {
	files := os.ls(path) or { return [] }
	mut returnval := []string{}
	for file in files {
		if !os.is_dir('$path/$file') {
			returnval << '$path/$file'
		} else {
			if file in ignored_folder {
				continue
			}
			returnval << r.get_all_files('$path/$file')
		}
	}
	return returnval
}

fn (r &Repo) format_commits_count() vweb.RawHtml {
	nr := r.commits_count

	if nr == 1 {
		return '<b>1</b> commit'
	}

	return '<b>$nr</b> commits'
}

fn (r &Repo) format_branches_count() vweb.RawHtml {
	nr := r.branches_count

	if nr == 1 {
		return '<b>1</b> branch'
	}

	return '<b>$nr</b> branches'
}

fn (r &Repo) format_open_prs_count() vweb.RawHtml {
	nr := r.open_prs_count

	if nr == 1 {
		return '<b>1</b> pull request'
	}

	return '<b>$nr</b> pull requests'
}

fn (r &Repo) format_open_issues_count() vweb.RawHtml {
	nr := r.open_issues_count

	if nr == 1 {
		return '<b>1</b> issue'
	}

	return '<b>$nr</b> issues'
}

fn (r &Repo) format_contributors_count() vweb.RawHtml {
	nr := r.contributors_count

	if nr == 1 {
		return '<b>1</b> contributor'
	}

	return '<b>$nr</b> contributors'
}

fn (r &Repo) format_topics_count() vweb.RawHtml {
	nr := r.topics_count

	if nr == 1 {
		return '<b>1</b> discussion'
	}

	return '<b>$nr</b> discussions'
}

fn (r &Repo) format_releases_count() vweb.RawHtml {
	nr := r.releases_count

	if nr == 1 {
		return '<b>1</b> release'
	}

	return '<b>$nr</b> releases'
}

// TODO: return ?string
fn (r &Repo) git(command string) string {
	if command.contains('&') || command.contains(';') {
		return ''
	}

	command_with_path := '-C $r.git_dir $command'

	command_result := os.execute('git $command_with_path')
	command_exit_code := command_result.exit_code
	if command_exit_code != 0 {
		println('git error $command_with_path with $command_exit_code exit code out=$command_result.output')

		return ''
	}

	return command_result.output.trim_space()
}

fn (r &Repo) parse_ls(ls string, branch string) ?File {
	words := ls.fields()

	if words.len < 4 {
		return none
	}
	typ := words[1]
	mut parent_path := os.dir(words[3])
	hash := r.git('log $branch -n 1 --format="%h" -- ${words[3]}')

	name := words[3].after('/')
	if name == '' {
		return none
	}
	if parent_path == name {
		parent_path = ''
	}
	if name.contains('"\\') {
		// Unqoute octal UTF-8 strings
	}

	return File{
		name: name
		parent_path: parent_path
		repo_id: r.id
		last_hash: hash
		branch: branch
		is_dir: typ == 'tree'
	}
}

// Fetches all files via `git ls-tree` and saves them in db
fn (mut app App) cache_repo_files(mut r Repo, branch string, path string) []File {
	if r.status == .caching {
		app.info('`$r.name` is being cached already')
		return []
	}

	mut res := ''
	if path == '.' {
		r.status = .caching
		defer {
			r.status = .done
		}
	} else {
		mut p := path
		if path != '' {
			p += '/'
		}
		res = r.git('ls-tree --full-name $branch $p')
	}
	lines := res.split('\n')
	mut dirs := []File{} // dirs first
	mut files := []File{}

	app.db.exec('BEGIN TRANSACTION')
	for line in lines {
		is_line_empty := validation.is_string_empty(line)

		if is_line_empty {
			continue
		}

		file := r.parse_ls(line, branch) or {
			app.warn('failed to parse $line')
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

fn (r Repo) html_path_to(path string, branch string) vweb.RawHtml {
	vals := path.trim_space().trim_right('/').split('/')
	mut res := ''
	mut growp := ''
	for i, val in vals {
		if val == '' {
			continue
		}
		// Last element is not a link
		if i == vals.len - 1 {
			res += val
		} else {
			if val != '' {
				growp += '/' + val
			}
			res += '<a href="/tree$growp/">$val</a> / '
		}
	}
	if res != '' {
		res = '/ ' + res
	}
	return res
}

// fetches last message and last time for each file
// this is slow, so it's run in the background thread
fn (mut app App) slow_fetch_files_info(branch string, path string) {
	files := app.find_repository_items(app.repo.id, branch, path)

	for i in 0 .. files.len {
		if files[i].last_msg != '' {
			app.warn('skipping ${files[i].name}')
			continue
		}

		app.fetch_file_info(app.repo, files[i])
	}
}

fn (r Repo) git_advertise(service string) string {
	git_result := os.execute('git $service --stateless-rpc --advertise-refs $r.git_dir')
	git_output := git_result.output

	if git_result.exit_code != 0 {
		eprintln('git $service error: $git_output')
	}

	return git_output
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

	process.wait()

	output := process.stdout_slurp()
	errors := process.stderr_slurp()

	process.close()

	if errors.len > 0 {
		eprintln('git $service error: $errors')

		return ''
	}

	return output
}

fn (mut app App) generate_clone_url() string {
	hostname := app.settings.hostname
	username := app.repo.user_name
	repository_name := app.repo.name

	return 'https://$hostname/$username/${repository_name}.git'
}

fn first_line(s string) string {
	pos := s.index('\n') or { return s }
	return s[..pos]
}

fn (mut app App) fetch_file_info(r &Repo, file &File) {
	logs := r.git('log -n1 --format=%B___%at___%H___%an $file.branch -- $file.full_path()')
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

fn (mut app App) update_repository_primary_branch(repository_id int, branch string) {
	sql app.db {
		update Repo set primary_branch = branch where id == repository_id
	}
}

fn (mut r Repo) clone() {
	clone_result := os.execute('git clone --bare "$r.clone_url" $r.git_dir')
	close_exit_code := clone_result.exit_code

	if close_exit_code != 0 {
		r.status = .clone_failed
		println('git clone failed with exit code $close_exit_code')
		return
	}

	r.status = .clone_done
}
