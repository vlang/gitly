// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import os
import hl
import sync
import vweb

struct Repo {
	id                 int
	git_dir            string
	name               string
	user_id            int
	clone_url          string [skip]
	primary_branch     string [skip]
	description        string
	is_public          bool [skip]
	users_contributed  []string [skip]
	users_authorized   []string [skip]
	nr_topics          int [skip]
	nr_views           int
	latest_update_hash string [skip]
	latest_activity    time.Time [skip]
mut:
	nr_tags            int
	branches           []Branch [skip]
	nr_open_issues     int
	nr_open_prs        int
	nr_releases        int
	nr_branches        int
	lang_stats         []LangStat [skip]
	created_at         int //time.Time
	nr_contributors    int
	nr_commits         int
	labels             []Label [skip]
	status             RepoStatus [skip]
	msg_cache          map[string]string [skip]
}

const (
	max_git_res_size = 1000
	log_field_separator = '\x7F' // declared as constant in case we need to change it later
)

enum RepoStatus {
	done
	caching
}

fn (mut app App) update_repo() {
	mut r := &app.repo
	wg := sync.new_waitgroup()
	wg.add(1)
	go r.analyse_lang(wg)
	data := r.git('--no-pager log --abbrev-commit --abbrev=7 --pretty="%h$log_field_separator%aE$log_field_separator%cD$log_field_separator%s$log_field_separator%aN"')
	mut tmp_commit := Commit{}
	r.nr_contributors = 0
	r.nr_commits = 0
	app.db.exec('BEGIN TRANSACTION')
	for line in data.split_into_lines() {
		args := line.split(log_field_separator)
		if args.len > 3 {
			tmp_commit.repo_id = r.id
			tmp_commit.hash = args[0]
			tmp_commit.author = args[4]
			t := time.parse_rfc2822(args[2]) or {
				app.error('Error: $err')
				return
			}
			tmp_commit.created_at = int(t.unix)
			tmp_commit.message = args[3]

			user := app.find_user_by_email(args[1]) or { User{} }
			if user.username != '' {
				app.insert_contributor(Contributor{
					user: user.id
					repo: r.id
				})
				tmp_commit.author_id = user.id
			} else {
				app.insert_contributor(Contributor{
					repo: r.id
					name: tmp_commit.author
				})
			}
			app.insert_commit(tmp_commit)
		}
	}
	r.nr_commits = app.commits_by_repo_id_size(r.id)
	r.nr_contributors = app.contributor_by_repo_id_size(r.id)
	app.info(r.nr_contributors.str())
	r.created_at = int(tmp_commit.created_at)
	r.branches = get_branches(r)
	r.nr_branches = r.branches.len
	// TODO: TEMPORARY - UNTIL WE GET PERSISTENT RELEASE INFO
	r.nr_releases = 0
	for tag in app.find_tags_by_repo_id(r.id) {
		release := &Release{
			tag_id: tag.id
			repo_id: r.id
			notes: 'Some notes about this release...'
		}
		app.insert_release(release)
		r.nr_releases++
	}
	wg.wait()
	repo := *r
	lang_stats := repo.lang_stats
	app.info(repo.git_dir)
	sql app.db {
		insert repo into Repo
	}
	for lang_stat in lang_stats {
		sql app.db {
			insert lang_stat into LangStat
		}
	}
	app.db.exec('END TRANSACTION')
	app.info('Repo updated')
}

// update_repo updated the repo in the db
fn (mut r Repo) update_repo() {}

fn (mut r Repo) analyse_lang(wg &sync.WaitGroup) {
	files := r.get_all_files(r.git_dir)
	mut all_size := 0
	mut lang_stats := map[string]int
	mut langs := map[string]hl.Lang

	for file in files {
		lang := hl.extension_to_lang(file.split('.').last()) or {
			continue
		}
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
	r.lang_stats = []LangStat{}
	mut tmp_a := []int{}
	for lang, amount in lang_stats {
		mut tmp := f32(amount) / f32(all_size)
		tmp *= 1000
		pct := int(tmp)
		if pct !in tmp_a {
			tmp_a << pct
		}
		lang_data := langs[lang]
		r.lang_stats << LangStat{
			id: 0
			repo_id: r.id
			name: lang_data.name
			pct: pct
			color: lang_data.color
			nr_lines: amount
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
	r.lang_stats = tmp_stats
	wg.done()
}

fn calc_lines_of_code(lines []string, lang hl.Lang) int {
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
				if tmp_line.starts_with(mlcomment_start) { continue }
			}
			if tmp_line.contains(mlcomment_end) {
				if in_comment {
					in_comment = false
				}
				if tmp_line.ends_with(mlcomment_end) { continue }
			}
			if in_comment { continue }
			if tmp_line.contains(lcomment) {
				if tmp_line.starts_with(lcomment) { continue }
			}
			size++
		}
	}
	return size
}

fn (r Repo) get_all_files(path string) []string {
	files := os.ls(path) or { panic(err) }
	mut returnval := []string{}
	for file in files {
		if !os.is_dir('$path/$file') {
			returnval << '$path/$file'
		} else {
			if file in ignored_folder { continue }
			returnval << r.get_all_files('$path/$file')
		}
	}
	return returnval
}

fn (r &Repo) nr_commits_fmt() vweb.RawHtml{
	nr := r.nr_commits
	if nr == 1 {
		return '<b>1</b> commit'
	}
	return '<b>$nr</b> commits'
}

fn (r &Repo) nr_branches_fmt() vweb.RawHtml{
	nr := r.nr_branches
	if nr == 1 {
		return '<b>1</b> branch'
	}
	return '<b>$nr</b> branches'
}

fn (r &Repo) nr_open_prs_fmt() vweb.RawHtml{
	nr := r.nr_open_prs
	if nr == 1 {
		return '<b>1</b> pull request'
	}
	return '<b>$nr</b> pull requests'
}

fn (r &Repo) nr_open_issues_fmt() vweb.RawHtml{
	nr := r.nr_open_issues
	if nr == 1 {
		return '<b>1</b> issue'
	}
	return '<b>$nr</b> issues'
}

fn (r &Repo) nr_contributors_fmt() vweb.RawHtml{
	nr := r.nr_contributors
	if nr == 1 {
		return '<b>1</b> contributor'
	}
	return '<b>$nr</b> contributors'
}

fn (r &Repo) nr_topics_fmt() vweb.RawHtml{
	nr := r.nr_topics
	if nr == 1 {
		return '<b>1</b> discussion'
	}
	return '<b>$nr</b> discussions'
}

fn (r &Repo) nr_releases_fmt() vweb.RawHtml{
	nr := r.nr_releases
	if nr == 1 {
		return '<b>1</b> release'
	}
	return '<b>$nr</b> releases'
}

fn (r &Repo) git(cmd_ string) string {
	mut cmd := cmd_
	if cmd.contains('&') || cmd.contains(';') {
		return ''
	}
	/*
	if op == "checkout" || op == "merge" || op == "diff" || op == "reset" {
			gitdir += "/.."
		}
	*/
	if !cmd.starts_with('init') {
		cmd = '-C $r.git_dir $cmd'
	}
	x := os.exec('git $cmd') or {
		// if !q.ContainsString(args, "master:README.md") {
		println('git error $cmd out=x.output')
		return ''
		// }
	}
	res := x.output.trim_space()
	if res.len > max_git_res_size {
		println('Huge git() output: $res.len KB $cmd')
	}
	return res
}

fn (r &Repo) parse_ls(ls, branch string) ?File {
	words := ls.fields()
	// println(words)
	if words.len < 4 {
		return none
	}
	typ := words[1]
	mut parent_path := os.base_dir(words[3])
	hash := words[2]
	println(hash)
	name := words[3].after('/') // os.basename(words[3])
	// println('parse ls name=$name path=$path')
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
		is_dir: typ == 'tree'
	}
}

// Fetches all files via `git ls-tree` and saves them in db
fn (mut app App) cache_repo_files(mut r Repo, branch, path string) []File {
	app.info('Repo.cache_files($r.name branch=$branch path=$path)')
	app.info('path.len=$path.len')
	if r.status == .caching {
		app.error('repo `$r.name` is being cached already')
		return []
	}
	// ls-tree --name-only trunk
	mut res := ''
	if path == '.' {
		r.status = .caching
		defer {
			r.status = .done
		}
		//res = r.git('ls-tree --full-tree --full-name -rt $branch')
		// defer r.UpdateAllFilesSizeAndLines()
	} else {
		mut p := path
		if path != '' {
			p += '/'
		}
		//t := time.ticks()
		//println('ls-tree --full-name $branch $p')
		res = r.git('ls-tree --full-name $branch $p --abbrev=7')
		//println('ls tree res:')
		//println(res)
		//println('ls-tree ms=${time.ticks() - t}')
	}
	lines := res.split('\n')
	mut dirs := []File{} // dirs first
	mut files := []File{}
	app.db.exec('BEGIN TRANSACTION')
	for line in lines {
		file := r.parse_ls(line, branch) or {
			app.warn('failed to parse $line')
			continue
		}
		if file.is_dir {
			dirs << file
			app.insert_file(file)
		} else {
			files << file
		}
	}
	dirs << files
	for file in files {
		app.insert_file(file)
	}
	app.db.exec('END TRANSACTION')
	return dirs
}

fn (r &Repo) html_path_to(path, branch string) vweb.RawHtml {
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
			// res += '<a href="/$r.name/tree/$branch/$growp/">$val</a> / '
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
	files := app.find_files_by_repo(app.repo.id, branch, path)
	// t := time.ticks()
	// for file in files {
	for i in 0 .. files.len {
		if files[i].last_msg != '' {
			app.warn('skipping ${files[i].name}')
			continue
		}
		app.fetch_file_info(app.repo, files[i])
	}
	// println('slow fetch file info= ${time.ticks()-t}ms')
}

fn (r Repo) git_advertise(a string) string {
	cmd := os.exec('git $a --stateless-rpc --advertise-refs $r.git_dir') or { panic(err) }
	if cmd.exit_code != 0 {
		//eprintln("advertise error", err)
		//eprintln("\n\ngit advertise output: $cmd.output\n\n")
	}
	return cmd.output
}

fn first_line(s string) string {
	pos := s.index('\n') or {
		return s
	}
	return s[..pos]
}

fn (mut app App) fetch_file_info(r &Repo, file &File) {
	logs := r.git('log -n1 --format=%B___%at___%H___%an $file.branch -- $file.full_path()')
	vals := logs.split('___')
	//println("fetch_file_info() vals=")
	//println(vals)
	if vals.len < 3 {
		return
	}
	last_msg := first_line(vals[0])
	last_time:= vals[1].int()
	/*last_hash*/_ := vals[2]
	/*last_author*/_ := vals[3]
	file_id := file.id
	sql app.db {
		update File set last_msg = last_msg, last_time = last_time where id == file_id
	}
}

