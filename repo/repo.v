// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time
import git
import highlight
import validation
import config

struct Repo {
	id                 int @[primary; sql: serial]
	git_dir            string
	name               string
	user_id            int
	user_name          string
	clone_url          string @[skip]
	description        string
	is_public          bool
	is_deleted         bool
	users_contributed  []string @[skip]
	users_authorized   []string @[skip]
	nr_topics          int      @[skip]
	views_count        int
	latest_update_hash string    @[skip]
	latest_activity    time.Time @[skip]
mut:
	primary_branch      string
	webhook_secret      string
	tags_count          int
	nr_open_issues      int @[orm: 'open_issues_count']
	nr_open_prs         int @[orm: 'open_prs_count']
	nr_releases         int @[orm: 'releases_count']
	nr_branches         int @[orm: 'branches_count']
	nr_tags             int
	nr_stars            int        @[orm: 'stars_count']
	lang_stats          []LangStat @[skip]
	created_at          int
	nr_contributors     int
	labels              []Label @[skip]
	status              RepoStatus
	msg_cache           map[string]string @[skip]
	latest_commit_at    int               @[skip]
	activity_buckets    []int             @[skip]
	disable_discussions bool
	disable_projects    bool
	disable_milestones  bool
	disable_wiki        bool
	is_pinned           bool
}

fn (r &Repo) discussions_enabled() bool {
	return !r.disable_discussions
}

fn (r &Repo) projects_enabled() bool {
	return !r.disable_projects
}

fn (r &Repo) milestones_enabled() bool {
	return !r.disable_milestones
}

fn (r &Repo) wiki_enabled() bool {
	return !r.disable_wiki
}

// log_field_separator is declared as constant in case we need to change it later
const max_git_res_size = 1000
const max_free_clone_size_bytes = u64(100) * 1024 * 1024
const log_field_separator = '\x7F'
const ignored_folder = ['thirdparty']

enum RepoStatus {
	done         = 0
	caching      = 1
	clone_failed = 2
	cloning      = 3
}

enum CloneReuseResult {
	unavailable
	reused
	failed
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

fn (mut app App) save_repo(repo Repo) ! {
	id := repo.id
	desc := repo.description
	views_count := repo.views_count
	webhook_secret := repo.webhook_secret
	tags_count := repo.tags_count
	is_public := repo.is_public // if repo.is_public { 1 } else { 0 } // SQLITE hack
	open_issues_count := repo.nr_open_issues
	open_prs_count := repo.nr_open_prs
	branches_count := repo.nr_branches
	releases_count := repo.nr_releases
	stars_count := repo.nr_stars
	contributors_count := repo.nr_contributors

	// XTODO sql update all fields automatically
	// repo.update()

	sql app.db {
		update Repo set description = desc, views_count = views_count, is_public = is_public,
		webhook_secret = webhook_secret, tags_count = tags_count, nr_open_issues = open_issues_count,
		nr_open_prs = open_prs_count, nr_releases = releases_count, nr_contributors = contributors_count,
		nr_stars = stars_count, nr_branches = branches_count where id == id
	}!
}

fn (app App) find_repo_by_name_and_user_id(repo_name string, user_id int) ?Repo {
	repos := sql app.db {
		select from Repo where name == repo_name && user_id == user_id && is_deleted == false limit 1
	} or { return none }

	if repos.len == 0 {
		return none
	}

	mut repo := repos[0]
	repo.lang_stats = app.find_repo_lang_stats(repo.id)
	println('GIT DIR = ${repo.git_dir}')

	return repo
}

fn (app App) find_repo_by_name_and_username(repo_name string, username string) ?Repo {
	repos := sql app.db {
		select from Repo where name == repo_name && user_name == username && is_deleted == false limit 1
	} or { return none }
	if repos.len == 0 {
		return none
	}
	mut repo := repos.first()
	repo.lang_stats = app.find_repo_lang_stats(repo.id)
	return repo
}

fn (mut app App) get_count_user_repos(user_id int) int {
	return sql app.db {
		select count from Repo where user_id == user_id && is_deleted == false
	} or { 0 }
}

fn (mut app App) find_user_repos(user_id int) []Repo {
	return sql app.db {
		select from Repo where user_id == user_id && is_deleted == false
	} or { []Repo{} }
}

fn (mut app App) find_user_public_repos(user_id int) []Repo {
	return sql app.db {
		select from Repo where user_id == user_id && is_public == true && is_deleted == false
	} or { []Repo{} }
}

const profile_repos_limit = 6

fn (mut app App) find_user_pinned_repos(user_id int, include_private bool) []Repo {
	limit := profile_repos_limit
	if include_private {
		return sql app.db {
			select from Repo where user_id == user_id && is_pinned == true && is_deleted == false limit limit
		} or { []Repo{} }
	}
	return sql app.db {
		select from Repo where user_id == user_id && is_pinned == true && is_public == true
		&& is_deleted == false limit limit
	} or { []Repo{} }
}

fn (mut app App) find_user_top_repos_by_stars(user_id int, include_private bool, l int) []Repo {
	if include_private {
		return sql app.db {
			select from Repo where user_id == user_id && is_deleted == false order by nr_stars desc limit l
		} or { []Repo{} }
	}
	return sql app.db {
		select from Repo where user_id == user_id && is_public == true && is_deleted == false order by nr_stars desc limit l
	} or { []Repo{} }
}

fn (mut app App) find_user_profile_repos(user_id int, include_private bool) []Repo {
	pinned := app.find_user_pinned_repos(user_id, include_private)
	if pinned.len > 0 {
		return pinned
	}
	return app.find_user_top_repos_by_stars(user_id, include_private, profile_repos_limit)
}

fn (mut app App) search_public_repos(query string) []Repo {
	repo_rows := db_exec_values(mut app.db,
		'select id, name, user_id, description, stars_count from ${sql_table('Repo')} where is_public is true and is_deleted is false and name like ${sql_like_pattern(query)}') or {
		return []
	}

	mut repos := []Repo{}

	for row in repo_rows {
		user_id := row[2].int()
		user := app.get_user_by_id(user_id) or { User{} }

		repos << Repo{
			id:          row[0].int()
			name:        row[1]
			user_name:   user.username
			description: row[3]
			nr_stars:    row[4].int()
		}
	}

	return repos
}

fn (app &App) find_repo_by_id(repo_id int) ?Repo {
	repos := sql app.db {
		select from Repo where id == repo_id && is_deleted == false
	} or { []Repo{} }

	if repos.len == 0 {
		return none
	}

	mut repo := repos.first()
	repo.lang_stats = app.find_repo_lang_stats(repo.id)

	return repo
}

fn normalized_non_github_clone_url(value string) string {
	mut s := value.trim_space()
	if idx := s.index('?') {
		s = s[..idx]
	}
	if idx := s.index('#') {
		s = s[..idx]
	}
	for s.ends_with('/') {
		s = s[..s.len - 1]
	}
	if s.ends_with('.git') {
		s = s[..s.len - '.git'.len]
	}
	for s.ends_with('/') {
		s = s[..s.len - 1]
	}
	lower := s.to_lower()
	for prefix in ['https://', 'http://'] {
		if lower.starts_with(prefix) {
			return s[prefix.len..]
		}
	}
	return s
}

fn same_clone_source_url(a string, b string) bool {
	if a.trim_space() == '' || b.trim_space() == '' {
		return false
	}
	if is_github_clone_url(a) && is_github_clone_url(b) {
		a_owner, a_repo := parse_github_owner_repo(a) or { return false }
		b_owner, b_repo := parse_github_owner_repo(b) or { return false }
		return a_owner.to_lower() == b_owner.to_lower() && a_repo.to_lower() == b_repo.to_lower()
	}
	return normalized_non_github_clone_url(a) == normalized_non_github_clone_url(b)
}

fn repo_origin_url(repo_dir string) ?string {
	if repo_dir == '' || !os.exists(repo_dir) || !os.is_dir(repo_dir) {
		return none
	}
	res := git.Git.exec_in_dir(repo_dir, ['config', '--get', 'remote.origin.url'])
	if res.exit_code != 0 {
		return none
	}
	origin_url := res.output.trim_space()
	if origin_url == '' {
		return none
	}
	return origin_url
}

fn (mut app App) find_reusable_clone_source(clone_url string, target_repo_id int) ?Repo {
	done_status := RepoStatus.done
	repos := sql app.db {
		select from Repo where is_deleted == false && status == done_status order by id desc
	} or { []Repo{} }

	for repo in repos {
		if repo.id == target_repo_id {
			continue
		}
		origin_url := repo_origin_url(repo.git_dir) or { continue }
		if same_clone_source_url(origin_url, clone_url) {
			return repo
		}
	}
	return none
}

fn (mut app App) increment_repo_views(repo_id int) ! {
	sql app.db {
		update Repo set views_count = views_count + 1 where id == repo_id
	}!
}

fn (mut app App) increment_repo_stars(repo_id int) ! {
	sql app.db {
		update Repo set nr_stars = nr_stars + 1 where id == repo_id
	}!
}

fn (mut app App) decrement_repo_stars(repo_id int) ! {
	sql app.db {
		update Repo set nr_stars = nr_stars - 1 where id == repo_id
	}!
}

fn (mut app App) increment_file_views(file_id int) ! {
	sql app.db {
		update File set views_count = views_count + 1 where id == file_id
	}!
}

fn (mut app App) set_repo_webhook_secret(repo_id int, secret string) ! {
	sql app.db {
		update Repo set webhook_secret = secret where id == repo_id
	}!
}

fn (mut app App) update_repo_features(repo_id int, disable_discussions bool, disable_projects bool, disable_milestones bool, disable_wiki bool) ! {
	sql app.db {
		update Repo set disable_discussions = disable_discussions, disable_projects = disable_projects,
		disable_milestones = disable_milestones, disable_wiki = disable_wiki where id == repo_id
	}!
}

fn (mut app App) set_repo_status(repo_id int, status RepoStatus) ! {
	sql app.db {
		update Repo set status = status where id == repo_id
	}!
}

fn (mut app App) set_repo_description(repo_id int, description string) ! {
	sql app.db {
		update Repo set description = description where id == repo_id
	}!
}

fn (mut app App) update_repo_contributor_count(repo_id int) ! {
	count := app.get_count_repo_contributors(repo_id)!
	sql app.db {
		update Repo set nr_contributors = count where id == repo_id
	}!
}

fn (mut app App) increment_repo_issues(repo_id int) ! {
	sql app.db {
		update Repo set nr_open_issues = nr_open_issues + 1 where id == repo_id
	}!
}

fn (mut app App) get_count_repo() int {
	return sql app.db {
		select count from Repo where is_deleted == false
	} or { 0 }
}

fn (mut app App) get_max_repo_id() int {
	rows := sql app.db {
		select from Repo order by id desc limit 1
	} or { return 0 }
	if rows.len == 0 {
		return 0
	}
	return rows[0].id
}

fn (mut app App) add_repo(repo Repo) ! {
	mut repo_to_insert := repo
	if repo_to_insert.created_at <= 0 {
		repo_to_insert.created_at = int(time.now().unix())
	}
	sql app.db {
		insert repo_to_insert into Repo
	}!
}

fn (r &Repo) activity_svg_points() string {
	if r.activity_buckets.len == 0 {
		return ''
	}
	mut max := 1
	for v in r.activity_buckets {
		if v > max {
			max = v
		}
	}
	width := 120.0
	height := 28.0
	step := if r.activity_buckets.len > 1 {
		width / f64(r.activity_buckets.len - 1)
	} else {
		width
	}
	mut points := []string{cap: r.activity_buckets.len}
	for i, v in r.activity_buckets {
		x := f64(i) * step
		y := height - (f64(v) / f64(max)) * (height - 2.0) - 1.0
		points << '${x:.1f},${y:.1f}'
	}
	return points.join(' ')
}

fn (r &Repo) last_updated_str() string {
	if r.latest_commit_at <= 0 {
		return ''
	}
	return time.unix(r.latest_commit_at).relative()
}

fn (r &Repo) created_str() string {
	if r.created_at <= 0 {
		return ''
	}
	return time.unix(r.created_at).relative()
}

fn (r &Repo) last_activity_str() string {
	activity_at := r.last_activity_at()
	if activity_at <= 0 {
		return ''
	}
	return time.unix(activity_at).relative()
}

fn (r &Repo) last_activity_at() int {
	return if r.latest_commit_at > 0 { r.latest_commit_at } else { r.created_at }
}

fn (mut app App) delete_repository(id int, path string, name string) ! {
	sql app.db {
		update Repo set is_deleted = true where id == id
	}!
	app.info('Marked repo as deleted (${id}, ${name})')

	app.delete_repo_folder(path)
	app.info('Removed repo folder (${id}, ${name})')
}

fn (mut app App) move_repo_to_user(repo_id int, user_id int, user_name string) ! {
	sql app.db {
		update Repo set user_id = user_id, user_name = user_name where id == repo_id
	}!
}

fn (mut app App) user_has_repo(user_id int, repo_name string) bool {
	count := sql app.db {
		select count from Repo where user_id == user_id && name == repo_name && is_deleted == false
	} or { 0 }
	return count > 0
}

fn (mut app App) update_repo_from_fs(mut repo Repo, recompute_lang_stats bool) ! {
	println('UPDATE REPO FROM FS')
	repo_id := repo.id

	app.db.exec('BEGIN TRANSACTION')!

	// Language analysis reads every file in the repo and is slow on large
	// repos; callers on the git push hot path pass `false` and run it in a
	// background thread instead, so the git client is not blocked.
	if recompute_lang_stats {
		repo.analyze_lang(app)!
	}

	app.info(repo.nr_contributors.str())
	app.fetch_branches(repo)!

	branches_output := repo.git('branch -a')
	println('b output=${branches_output}')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.update_repo_branch_from_fs(mut repo, branch_name)!
	}

	repo.nr_contributors = app.get_count_repo_contributors(repo_id)!
	repo.nr_branches = app.get_count_repo_branches(repo_id)
	repo.nr_open_prs = app.get_repo_open_pr_count(repo_id)

	// TODO: TEMPORARY - UNTIL WE GET PERSISTENT RELEASE INFO
	for tag in app.get_all_repo_tags(repo_id) {
		app.add_release(tag.id, repo_id, time.unix(tag.created_at), tag.message)!

		repo.nr_releases++
	}

	app.save_repo(repo)!
	app.db.exec('END TRANSACTION')!
	app.info('Repo updated')
}

// fn (mut app App) update_repo_branch_from_fs(mut ctx Context, mut repo Repo, branch_name string) ! {
fn (mut app App) update_repo_branch_from_fs(mut repo Repo, branch_name string) ! {
	repo_id := repo.id
	branch := app.find_repo_branch_by_name(repo.id, branch_name)

	if branch.id == 0 {
		return
	}

	data :=
		repo.git('--no-pager log ${branch_name} --abbrev-commit --abbrev=7 --pretty="%h${log_field_separator}%aE${log_field_separator}%cD${log_field_separator}%s${log_field_separator}%aN"')

	for line in data.split_into_lines() {
		args := line.split(log_field_separator)

		if args.len > 4 {
			commit_hash := args[0]
			commit_author_email := args[1]
			commit_message := args[3]
			commit_author := args[4]
			mut commit_author_id := 0

			// git log outputs newest commits first; if this commit already
			// exists, all subsequent (older) commits do too — stop early.
			if app.commit_exists(repo_id, branch.id, commit_hash) {
				break
			}

			commit_date := time.parse_rfc2822(args[2]) or {
				app.info('Error: ${err}')
				return
			}

			user := app.get_user_by_email(commit_author_email) or { User{} }

			if user.id > 0 {
				app.add_contributor(user.id, repo_id)!

				commit_author_id = user.id
			}

			app.add_commit(repo_id, branch.id, commit_hash, commit_author, commit_author_id,
				commit_message, int(commit_date.unix()))!
		}
	}
}

fn (mut app App) update_repo_from_remote(mut repo Repo) ! {
	repo_id := repo.id

	repo.git('fetch --all')
	repo.git('pull --all')

	app.db.exec('BEGIN TRANSACTION')!

	repo.analyze_lang(app)!

	app.info(repo.nr_contributors.str())
	app.fetch_branches(repo)!
	app.fetch_tags(repo)!

	branches_output := repo.git('branch -a')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.update_repo_branch_from_fs(mut repo, branch_name)!
	}

	for tag in app.get_all_repo_tags(repo_id) {
		app.add_release(tag.id, repo_id, time.unix(tag.created_at), tag.message)!
		repo.nr_releases++
	}

	repo.nr_contributors = app.get_count_repo_contributors(repo_id)!
	repo.nr_branches = app.get_count_repo_branches(repo_id)
	repo.nr_open_prs = app.get_repo_open_pr_count(repo_id)

	app.save_repo(repo)!
	app.db.exec('END TRANSACTION')!
	app.info('Repo updated')
}

fn (mut app App) update_repo_branch_data(mut repo Repo, branch_name string) ! {
	repo_id := repo.id
	branch := app.find_repo_branch_by_name(repo.id, branch_name)

	if branch.id == 0 {
		return
	}

	data :=
		repo.git('--no-pager log ${branch_name} --abbrev-commit --abbrev=7 --pretty="%h${log_field_separator}%aE${log_field_separator}%cD${log_field_separator}%s${log_field_separator}%aN"')

	for line in data.split_into_lines() {
		args := line.split(log_field_separator)

		if args.len > 4 {
			commit_hash := args[0]
			commit_author_email := args[1]
			commit_message := args[3]
			commit_author := args[4]
			mut commit_author_id := 0

			if app.commit_exists(repo_id, branch.id, commit_hash) {
				break
			}

			commit_date := time.parse_rfc2822(args[2]) or {
				app.info('Error: ${err}')
				return
			}

			user := app.get_user_by_email(commit_author_email) or { User{} }

			if user.id > 0 {
				app.add_contributor(user.id, repo_id)!

				commit_author_id = user.id
			}

			app.add_commit(repo_id, branch.id, commit_hash, commit_author, commit_author_id,
				commit_message, int(commit_date.unix()))!
		}
	}
}

fn (mut app App) update_repo_branch_after_change(repo_id int, branch_name string) ! {
	if branch_name == '' {
		return
	}

	mut repo := app.find_repo_by_id(repo_id) or { return }

	app.db.exec('BEGIN TRANSACTION')!
	mut committed := false
	defer {
		if !committed {
			app.db.exec('ROLLBACK') or {}
		}
	}
	app.fetch_branch(repo, branch_name)!
	app.update_repo_branch_data(mut repo, branch_name)!
	repo.nr_contributors = app.get_count_repo_contributors(repo_id)!
	repo.nr_branches = app.get_count_repo_branches(repo_id)
	repo.nr_open_prs = app.get_repo_open_pr_count(repo_id)
	app.save_repo(repo)!
	app.db.exec('END TRANSACTION')!
	committed = true
}

// TODO: tags and other stuff
// update_repo_after_push runs on the request thread after a git push so that
// new commits appear in the UI immediately. It skips language analysis,
// which is slow and runs in bg_recompute_lang_stats instead.
fn (mut app App) update_repo_after_push(repo_id int, branch_name string) ! {
	mut repo := app.find_repo_by_id(repo_id) or { return }

	app.update_repo_from_fs(mut repo, false)!
	app.delete_repository_files_in_branch(repo_id, branch_name)!
}

// bg_recompute_lang_stats recomputes language statistics for a repo in a
// background thread. It opens its own sqlite connection (matching the
// clone_repo / bg_fetch_files_info pattern) because the shared App.db
// handle is not safe for concurrent use across threads.
fn bg_recompute_lang_stats(repo_id int, conf config.Config) {
	mut app := &App{
		db:     connect_db(conf) or {
			eprintln('bg_recompute_lang_stats: cannot open ${db_backend_name()} db: ${err}')
			return
		}
		config: conf
	}
	app.load_settings()
	defer {
		app.db.close() or {}
	}

	repo := app.find_repo_by_id(repo_id) or {
		eprintln('bg_recompute_lang_stats: repo ${repo_id} not found')
		return
	}
	repo.analyze_lang(app) or {
		eprintln('bg_recompute_lang_stats: analyze_lang failed for repo ${repo_id}: ${err}')
	}
}

fn (r &Repo) analyze_lang(app &App) ! {
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
			repo_id:     r.id
			name:        lang_data.name
			pct:         pct
			color:       lang_data.color
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

	app.remove_repo_lang_stats(r.id)!

	for lang_stat in d_lang_stats {
		app.add_lang_stat(lang_stat)!
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

	command_result := git.Git.exec_in_dir_command(r.git_dir, command)
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
		name:               item_name
		parent_path:        parent_path
		repo_id:            r.id
		branch:             branch
		is_dir:             item_type == 'tree'
		size:               if item_type == 'blob' { item_size.int() } else { 0 }
		is_size_calculated: item_type == 'blob'
	}
}

fn (r &Repo) parse_top_file_line(line string, branch string) ?File {
	tab_pos := line.index('\t') or { return none }
	meta := line[..tab_pos]
	item_path := line[tab_pos + 1..]
	meta_parts := meta.fields()
	if meta_parts.len < 4 || meta_parts[1] != 'blob' {
		return none
	}

	lower_path := item_path.to_lower()
	for segment in lower_path.split('/') {
		if segment == 'thirdparty' || segment == '3rdparty' || segment == 'third_party'
			|| segment == 'third-party' {
			return none
		}
	}

	excluded_extensions := ['.png', '.jpg', '.jpeg', '.obj', '.json', '.pdf']
	for ext in excluded_extensions {
		if lower_path.ends_with(ext) {
			return none
		}
	}

	item_name := item_path.after('/')
	if item_name == '' {
		return none
	}

	parent_path_raw := os.dir(item_path)
	parent_path := if parent_path_raw == '.' { '' } else { parent_path_raw }

	return File{
		name:               item_name
		parent_path:        parent_path
		repo_id:            r.id
		branch:             branch
		is_dir:             false
		size:               meta_parts[3].int()
		is_size_calculated: true
	}
}

fn (r &Repo) lookup_file_via_git(branch string, path string) ?File {
	git_result := git.Git.exec_in_dir(r.git_dir, ['ls-tree', '--full-name', '--long', branch, '--',
		path])
	if git_result.exit_code != 0 {
		return none
	}
	for line in git_result.output.split_into_lines() {
		tab_pos := line.index('\t') or { continue }
		meta := line[..tab_pos]
		item_path := line[tab_pos + 1..]
		meta_parts := meta.fields()
		if meta_parts.len < 4 || meta_parts[1] != 'blob' {
			continue
		}
		item_name := item_path.after('/')
		if item_name == '' {
			continue
		}
		parent_path_raw := os.dir(item_path)
		parent_path := if parent_path_raw == '.' { '' } else { parent_path_raw }
		return File{
			name:               item_name
			parent_path:        parent_path
			repo_id:            r.id
			branch:             branch
			is_dir:             false
			size:               meta_parts[3].int()
			is_size_calculated: true
		}
	}
	return none
}

fn (r &Repo) top_files(branch string, limit int) []File {
	git_result := git.Git.exec_in_dir(r.git_dir, ['ls-tree', '-r', '--full-name', '--long', branch])
	if git_result.exit_code != 0 {
		eprintln('git ls-tree top files error: ${git_result.output}')
		return []File{}
	}

	mut files := []File{}
	for line in git_result.output.split_into_lines() {
		file := r.parse_top_file_line(line, branch) or { continue }
		files << file
	}

	files.sort(b.size < a.size)
	if files.len > limit {
		return files[..limit]
	}

	return files
}

// Fetches all files via `git ls-tree` and saves them in db
fn (mut app App) cache_repository_items(mut r Repo, branch string, path string) ![]File {
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
		repository_ls =
			r.git('ls-tree --full-name --format="${format}" ${branch} ${directory_path}')
	}

	// mode type name path
	item_info_lines := repository_ls.split('\n')

	mut dirs := []File{} // dirs first
	mut files := []File{}

	app.db.exec('BEGIN TRANSACTION')!

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

			app.add_file(file)!
		} else {
			files << file
		}
	}

	dirs << files
	for file in files {
		app.add_file(file)!
	}

	app.db.exec('END TRANSACTION')!

	return dirs
}

// fetches last message and last time for each file
// this is slow, so it's run in the background thread
fn (mut app App) slow_fetch_files_info(mut repo Repo, branch string, path string) ! {
	files := app.find_repository_items(repo.id, branch, path)

	for i in 0 .. files.len {
		if files[i].last_msg != '' {
			app.warn('skipping ${files[i].name}')
			continue
		}

		app.fetch_file_info(repo, files[i])!
	}
}

fn (mut app App) slow_fetch_folder_sizes(mut repo Repo, branch string, path string) ! {
	files := app.find_repository_items(repo.id, branch, path)
	dirs := files.filter(it.is_dir && !it.is_size_calculated)
	if dirs.len == 0 {
		return
	}

	dir_names := dirs.map(it.name)
	sizes := repo.calculate_child_folder_sizes(branch, path, dir_names)

	for dir in dirs {
		size := sizes[dir.name] or { 0 }
		app.update_file_size(dir.id, size, true)!
	}
}

fn (r &Repo) calculate_child_folder_sizes(branch string, path string, dir_names []string) map[string]int {
	mut sizes := map[string]int{}
	for dir_name in dir_names {
		sizes[dir_name] = 0
	}
	if dir_names.len == 0 {
		return sizes
	}

	normalized_path := normalize_tree_path(path)
	mut args := ['ls-tree', '-r', '--full-name', '--long', branch]
	if normalized_path != '' {
		args << '--'
		args << normalized_path
	}

	result := git.Git.exec_in_dir(r.git_dir, args)
	if result.exit_code != 0 {
		eprintln('git ls-tree error while calculating folder sizes: ${result.output}')
		return sizes
	}

	prefix := if normalized_path == '' { '' } else { '${normalized_path}/' }
	for line in result.output.split_into_lines() {
		tab_pos := line.index('\t') or { continue }
		meta := line[..tab_pos]
		item_path := line[tab_pos + 1..]
		meta_parts := meta.fields()
		if meta_parts.len < 4 || meta_parts[1] != 'blob' {
			continue
		}

		mut relative_path := item_path
		if prefix != '' {
			if !item_path.starts_with(prefix) {
				continue
			}
			relative_path = item_path[prefix.len..]
		}

		slash_pos := relative_path.index('/') or { continue }
		child_dir := relative_path[..slash_pos]
		if child_dir !in sizes {
			continue
		}

		sizes[child_dir] = sizes[child_dir] + meta_parts[3].int()
	}

	return sizes
}

fn normalize_tree_path(path string) string {
	return path.trim_string_left('/').trim_string_right('/')
}

fn (r Repo) get_last_branch_commit_hash(branch_name string) string {
	git_result := git.Git.exec_in_dir(r.git_dir,
		['log', '-n', '1', branch_name, '--pretty=format:%h'])
	git_output := git_result.output

	if git_result.exit_code != 0 {
		eprintln('git log error: ${git_output}')
	}

	return git_output
}

fn (r Repo) git_advertise(service string) string {
	git_result := git.Git.exec([service, '--stateless-rpc', '--advertise-refs', r.git_dir])
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

fn (mut app App) fetch_file_info(r &Repo, file &File) ! {
	logs := r.git('log -n1 --format=%B___%at___%H___%an ${file.branch} -- ${file.full_path()}')
	vals := logs.split('___')
	if vals.len < 3 {
		return
	}
	last_msg := first_line(vals[0])
	last_time := vals[1].int()
	last_hash := vals[2]

	file_id := file.id
	sql app.db {
		update File set last_msg = last_msg, last_time = last_time, last_hash = last_hash
		where id == file_id
	}!
}

fn (mut app App) update_file_size(file_id int, size int, is_size_calculated bool) ! {
	sql app.db {
		update File set size = size, is_size_calculated = is_size_calculated where id == file_id
	}!
}

fn (mut app App) update_repo_primary_branch(repo_id int, branch string) ! {
	sql app.db {
		update Repo set primary_branch = branch where id == repo_id
	}!
}

fn (r &Repo) clone_progress_path() string {
	return r.git_dir + '.progress'
}

fn directory_size(path string) u64 {
	if !os.exists(path) {
		return 0
	}
	if !os.is_dir(path) {
		return os.file_size(path)
	}
	mut total := u64(0)
	for entry in os.ls(path) or { return total } {
		total += directory_size(os.join_path(path, entry))
	}
	return total
}

fn mark_clone_size_limit(progress_path string) {
	mut log := os.open_append(progress_path) or {
		os.write_file(progress_path, '${git.clone_size_limit_marker}\n') or {}
		return
	}
	log.write_string('\n${git.clone_size_limit_marker}\n') or {}
	log.close()
}

fn cleanup_oversized_clone(repo_path string) {
	os.rmdir_all(repo_path) or { eprintln('failed to remove oversized clone ${repo_path}: ${err}') }
}

fn append_clone_progress(progress_path string, message string) {
	mut log := os.open_append(progress_path) or {
		os.write_file(progress_path, '${message}\n') or {}
		return
	}
	log.write_string('${message}\n') or {}
	log.close()
}

fn git_result_ok(res os.Result) bool {
	return res.exit_code == 0 && !res.output.to_lower().contains('fatal')
}

fn remote_default_branch(repo_dir string) ?string {
	res := git.Git.exec_in_dir(repo_dir, ['ls-remote', '--symref', 'origin', 'HEAD'])
	if !git_result_ok(res) {
		return none
	}
	for line in res.output.split_into_lines() {
		if !line.starts_with('ref: refs/heads/') || !line.ends_with('\tHEAD') {
			continue
		}
		branch := line['ref: refs/heads/'.len..line.len - '\tHEAD'.len].trim_space()
		if branch != '' {
			return branch
		}
	}
	return none
}

fn local_head_branch(repo_dir string) ?string {
	res := git.Git.exec_in_dir(repo_dir, ['symbolic-ref', '--quiet', '--short', 'HEAD'])
	if !git_result_ok(res) {
		return none
	}
	branch := res.output.trim_space()
	if branch == '' {
		return none
	}
	return branch
}

fn repo_has_branch(repo_dir string, branch string) bool {
	if branch == '' {
		return false
	}
	res := git.Git.exec_in_dir(repo_dir,
		['show-ref', '--verify', '--quiet', 'refs/heads/${branch}'])
	return res.exit_code == 0
}

fn detect_primary_branch(repo_dir string, fallback string) string {
	for branch in [remote_default_branch(repo_dir) or { '' },
		local_head_branch(repo_dir) or { '' }, fallback, 'main', 'master'] {
		if repo_has_branch(repo_dir, branch) {
			return branch
		}
	}
	return fallback
}

fn point_head_to_branch(repo_dir string, branch string) bool {
	if branch == '' {
		return false
	}
	res := git.Git.exec_in_dir(repo_dir, ['symbolic-ref', 'HEAD', 'refs/heads/${branch}'])
	return git_result_ok(res)
}

fn (mut r Repo) clone_from_existing(source Repo, enforce_size_limit bool) CloneReuseResult {
	if source.git_dir == '' || source.git_dir == r.git_dir || !os.exists(source.git_dir)
		|| !os.is_dir(source.git_dir) || os.exists(r.git_dir) {
		return .unavailable
	}
	progress_path := r.clone_progress_path()
	os.rm(progress_path) or {}
	append_clone_progress(progress_path,
		'Reusing existing local clone from ${source.user_name}/${source.name}')
	tmp_path := '${r.git_dir}.tmp-${os.getpid()}-${time.ticks()}'
	os.rmdir_all(tmp_path) or {}
	os.cp_all(source.git_dir, tmp_path, false) or {
		append_clone_progress(progress_path,
			'Local clone reuse failed while copying; falling back to git clone.')
		os.rmdir_all(tmp_path) or {}
		eprintln('failed to copy reusable repo ${source.git_dir} to ${tmp_path}: ${err}')
		return .unavailable
	}
	os.mv(tmp_path, r.git_dir, overwrite: false) or {
		append_clone_progress(progress_path,
			'Local clone reuse failed while installing copy; falling back to git clone.')
		os.rmdir_all(tmp_path) or {}
		eprintln('failed to move reusable repo ${tmp_path} to ${r.git_dir}: ${err}')
		return .unavailable
	}
	set_url_result := git.Git.exec_in_dir(r.git_dir, ['remote', 'set-url', 'origin', r.clone_url])
	if !git_result_ok(set_url_result) {
		add_origin_result := git.Git.exec_in_dir(r.git_dir,
			['remote', 'add', 'origin', r.clone_url])
		if !git_result_ok(add_origin_result) {
			append_clone_progress(progress_path,
				'Local clone reuse failed while resetting origin; falling back to git clone.')
			os.rmdir_all(r.git_dir) or {}
			eprintln('failed to set origin for reused repo ${r.git_dir}: ${set_url_result.output}${add_origin_result.output}')
			return .unavailable
		}
	}
	append_clone_progress(progress_path, 'Fetching latest updates from origin')
	fetch_result := git.Git.exec_in_dir(r.git_dir, ['fetch', '--prune', 'origin',
		'+refs/heads/*:refs/heads/*', '+refs/tags/*:refs/tags/*'])
	if !git_result_ok(fetch_result) {
		append_clone_progress(progress_path,
			'Local clone reuse failed while fetching updates; falling back to git clone.')
		os.rmdir_all(r.git_dir) or {}
		eprintln('failed to fetch reused repo ${r.git_dir}: ${fetch_result.output}')
		return .unavailable
	}
	r.primary_branch = detect_primary_branch(r.git_dir, r.primary_branch)
	point_head_to_branch(r.git_dir, r.primary_branch)
	if enforce_size_limit && directory_size(r.git_dir) >= max_free_clone_size_bytes {
		r.status = .clone_failed
		mark_clone_size_limit(progress_path)
		cleanup_oversized_clone(r.git_dir)
		println('reused git clone removed because repo is larger than 100 MB')
		return .failed
	}
	r.status = .done
	os.rm(progress_path) or {}
	eprintln('clone reused from ${source.git_dir}')
	return .reused
}

fn (mut r Repo) clone(enforce_size_limit bool) {
	eprintln('R CLONE')
	progress_path := r.clone_progress_path()
	max_clone_size_bytes := if enforce_size_limit { max_free_clone_size_bytes } else { u64(0) }
	clone_result := git.Git.clone_with_progress_limit(r.clone_url, r.git_dir, progress_path,
		max_clone_size_bytes)
	clone_exit_code := clone_result.exit_code

	if enforce_size_limit && clone_exit_code == git.clone_size_limit_exit_code {
		r.status = .clone_failed
		mark_clone_size_limit(progress_path)
		cleanup_oversized_clone(r.git_dir)
		println('git clone stopped because repo is larger than 100 MB')
		return
	}

	if clone_exit_code != 0 {
		r.status = .clone_failed
		println('git clone failed with exit code ${clone_exit_code}')
		return
	}

	if enforce_size_limit && directory_size(r.git_dir) >= max_free_clone_size_bytes {
		r.status = .clone_failed
		mark_clone_size_limit(progress_path)
		cleanup_oversized_clone(r.git_dir)
		println('git clone removed because repo is larger than 100 MB')
		return
	}

	r.primary_branch = detect_primary_branch(r.git_dir, r.primary_branch)
	point_head_to_branch(r.git_dir, r.primary_branch)
	r.status = .done
	// progress file is no longer needed after a successful clone
	os.rm(progress_path) or {}
	eprintln('clone done')
}

fn (r &Repo) read_file(branch string, path string) string {
	valid_path := path.trim_string_left('/')

	println('read_file() path=${valid_path}')
	t := time.now()
	// s := r.git('--no-pager show ${branch}:${valid_path}')

	s := git.Git.show_file_blob(r.git_dir, branch, valid_path) or { '' }
	println(time.since(t))
	println(':)')
	return s
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
	// List of common license file names
	license_common_files := ['license', 'license.md', 'license.txt', 'licence', 'licence.md',
		'licence.txt']

	files := items.filter(license_common_files.contains(it.name.to_lower()))

	if files.len == 0 {
		return none
	}
	return files[0]
}

// can_read_repo reports whether the current request may read the given,
// already-loaded repo's contents (tree/blob/raw/contributors/...). Public
// repos are readable by anyone, including anonymous visitors; private repos
// are readable only by their owner. Call this on every repo-scoped read route
// before running a git command or returning repo data.
fn (app &App) can_read_repo(ctx Context, repo Repo) bool {
	if repo.is_public {
		return true
	}
	return ctx.logged_in && ctx.user.id != 0 && repo.user_id == ctx.user.id
}

fn (app &App) has_user_repo_read_access(ctx Context, user_id int, repo_id int) bool {
	if !ctx.logged_in {
		return false
	}
	repo := app.find_repo_by_id(repo_id) or { return false }
	if repo.is_public {
		return true
	}
	is_repo_owner := repo.user_id == user_id
	if is_repo_owner {
		return true
	}
	return false
}

fn (app &App) has_user_repo_read_access_by_repo_name(ctx Context, user_id int, repo_owner_name string, repo_name string) bool {
	user := app.get_user_by_username(repo_owner_name) or { return false }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id) or { return false }
	return app.has_user_repo_read_access(ctx, user_id, repo.id)
}

// can_admin_repo reports whether the currently logged-in user is allowed to
// administer (settings/delete/move/webhooks/...) the given, already-loaded
// target repo. It must be called with the repo loaded from the URL owner, not
// re-queried by the logged-in user's name — otherwise a user could pass the
// check for someone else's repo simply by owning a repo with the same name.
fn (app &App) can_admin_repo(ctx Context, repo Repo) bool {
	return ctx.logged_in && ctx.user.id != 0 && repo.user_id == ctx.user.id
}
