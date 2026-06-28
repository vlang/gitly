// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import validation
import git
import time
import strings

struct PrWithUser {
	pr   PullRequest
	user User
}

struct PrCommentWithUser {
	item PrComment
	user User
}

struct PrReviewWithUser {
	review   PrReview
	user     User
	comments []PrReviewComment
}

struct PrTimelineEntry {
mut:
	kind       string // 'comment' or 'review'
	created_at int
	user       User
	comment    PrComment
	review     PrReview
	rcomments  []PrReviewCommentWithUser
}

struct PrReviewCommentWithUser {
	item PrReviewComment
	user User
}

struct PrFileTreeRow {
	path       string
	name       string
	depth      int
	indent_px  int
	is_dir     bool
	is_new     bool
	is_deleted bool
	is_renamed bool
	additions  int
	deletions  int
}

fn build_pr_file_tree_rows(file_diffs []FileDiff) []PrFileTreeRow {
	mut sorted := file_diffs.clone()
	sorted.sort(a.path < b.path)
	mut rows := []PrFileTreeRow{}
	mut seen_dirs := map[string]bool{}
	for fd in sorted {
		parts := fd.path.split('/')
		if parts.len == 0 {
			continue
		}
		mut current_path := ''
		if parts.len > 1 {
			for idx := 0; idx < parts.len - 1; idx++ {
				part := parts[idx]
				if part == '' {
					continue
				}
				current_path = if current_path == '' { part } else { '${current_path}/${part}' }
				if current_path !in seen_dirs {
					seen_dirs[current_path] = true
					rows << PrFileTreeRow{
						path:      current_path
						name:      part
						depth:     idx
						indent_px: 10 + idx * 16
						is_dir:    true
					}
				}
			}
		}
		rows << PrFileTreeRow{
			path:       fd.path
			name:       parts[parts.len - 1]
			depth:      parts.len - 1
			indent_px:  10 + (parts.len - 1) * 16
			is_new:     fd.is_new
			is_deleted: fd.is_deleted
			is_renamed: fd.is_renamed
			additions:  fd.additions
			deletions:  fd.deletions
		}
	}
	return rows
}

// GET /:username/:repo_name/pulls
@['/:username/:repo_name/pulls']
pub fn (mut app App) handle_get_repo_pulls(mut ctx Context, username string, repo_name string) veb.Result {
	return app.repo_pulls(mut ctx, username, repo_name, 'open')
}

@['/:username/:repo_name/pulls/:tab']
pub fn (mut app App) repo_pulls(mut ctx Context, username string, repo_name string, tab string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	current_tab := if tab in ['open', 'closed', 'merged'] { tab } else { 'open' }
	status := match current_tab {
		'closed' { PrStatus.closed }
		'merged' { PrStatus.merged }
		else { PrStatus.open }
	}

	prs := app.find_repo_pull_requests(repo.id, status)
	mut prs_with_users := []PrWithUser{}
	for pr in prs {
		author := app.get_user_by_id(pr.author_id) or { continue }
		prs_with_users << PrWithUser{
			pr:   pr
			user: author
		}
	}
	_ := app.get_repo_open_pr_count(repo.id)
	tab_open_class := if current_tab == 'open' { 'pr-tab pr-tab--active' } else { 'pr-tab' }
	tab_merged_class := if current_tab == 'merged' { 'pr-tab pr-tab--active' } else { 'pr-tab' }
	tab_closed_class := if current_tab == 'closed' { 'pr-tab pr-tab--active' } else { 'pr-tab' }
	return $veb.html('templates/pulls.html')
}

// GET /:username/:repo_name/pulls/new
@['/:username/:repo_name/compare']
pub fn (mut app App) new_pull_request_form(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	branches := app.get_all_repo_branches(repo.id)
	base := if 'base' in ctx.query { ctx.query['base'] } else { repo.primary_branch }
	head := if 'head' in ctx.query { ctx.query['head'] } else { '' }
	mut commits := []Commit{}
	mut file_diffs := []FileDiff{}
	mut suggested_title := ''
	mut error_msg := ''
	mut has_compare := false
	if head != '' && head != base {
		has_compare = true
		if !app.contains_repo_branch(repo.id, head) || !app.contains_repo_branch(repo.id, base) {
			error_msg = 'Both base and compare branches must exist in this repository.'
			has_compare = false
		} else {
			commits = repo.list_commits_between(base, head)
			raw_diff := repo.diff_branches(base, head)
			file_diffs = parse_unified_diff(raw_diff)
			if commits.len > 0 {
				suggested_title = commits[0].message
			}
		}
	}
	return $veb.html('templates/new/pull.html')
}

// POST /:username/:repo_name/pulls
@['/:username/:repo_name/pulls'; post]
pub fn (mut app App) handle_create_pull_request(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	title := ctx.form['title']
	description := ctx.form['description']
	head := ctx.form['head']
	base := ctx.form['base']
	if validation.is_string_empty(title) || validation.is_string_empty(head)
		|| validation.is_string_empty(base) {
		ctx.error('Title, head and base branches are required')
		return ctx.redirect('/${username}/${repo_name}/compare?base=${base}&head=${head}')
	}
	if head == base {
		ctx.error('Head and base must differ')
		return ctx.redirect('/${username}/${repo_name}/compare')
	}
	if !app.contains_repo_branch(repo.id, head) || !app.contains_repo_branch(repo.id, base) {
		ctx.error('Branches not found')
		return ctx.redirect('/${username}/${repo_name}/compare')
	}
	commits := repo.list_commits_between(base, head)
	if commits.len == 0 {
		ctx.error('No commits between base and head')
		return ctx.redirect('/${username}/${repo_name}/compare?base=${base}&head=${head}')
	}
	pr_id := app.add_pull_request(repo.id, ctx.user.id, title, description, head, base) or {
		ctx.error('Could not create pull request')
		return ctx.redirect('/${username}/${repo_name}/compare')
	}
	app.increment_repo_open_prs(repo.id) or { app.info(err.str()) }
	app.dispatch_webhook(repo.id, 'pr', WebhookPrPayload{
		action: 'opened'
		repo:   '${username}/${repo_name}'
		number: pr_id
		title:  title
		author: ctx.user.username
		head:   head
		base:   base
	})
	return ctx.redirect('/${username}/${repo_name}/pull/${pr_id}')
}

// GET /:username/:repo_name/pull/:id
@['/:username/:repo_name/pull/:id']
pub fn (mut app App) pull_request(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	author := app.get_user_by_id(pr.author_id) or { return ctx.not_found() }
	commits := repo.list_commits_between(pr.base_branch, pr.head_branch)
	comments := app.get_pr_comments(pr.id)
	reviews := app.get_pr_reviews(pr.id)
	rcomments := app.get_pr_review_comments(pr.id)
	mut timeline := []PrTimelineEntry{}
	for c in comments {
		u := app.get_user_by_id(c.author_id) or { continue }
		timeline << PrTimelineEntry{
			kind:       'comment'
			created_at: c.created_at
			user:       u
			comment:    c
		}
	}
	for r in reviews {
		u := app.get_user_by_id(r.author_id) or { continue }
		mut r_comments := []PrReviewCommentWithUser{}
		for rc in rcomments {
			if rc.review_id == r.id {
				uu := app.get_user_by_id(rc.author_id) or { continue }
				r_comments << PrReviewCommentWithUser{
					item: rc
					user: uu
				}
			}
		}
		timeline << PrTimelineEntry{
			kind:       'review'
			created_at: r.created_at
			user:       u
			review:     r
			rcomments:  r_comments
		}
	}
	timeline.sort(a.created_at < b.created_at)
	is_repo_owner := repo.user_id == ctx.user.id
	can_merge := is_repo_owner && pr.is_open()
	can_close := pr.is_open() && (is_repo_owner || pr.author_id == ctx.user.id)
	can_reopen := pr.is_closed() && (is_repo_owner || pr.author_id == ctx.user.id)
	return $veb.html('templates/pull.html')
}

// GET /:username/:repo_name/pull/:id/files
@['/:username/:repo_name/pull/:id/files']
pub fn (mut app App) pull_request_files(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.has_user_repo_read_access(ctx, ctx.user.id, repo.id) && !repo.is_public {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	author := app.get_user_by_id(pr.author_id) or { return ctx.not_found() }
	raw_diff := repo.diff_branches(pr.base_branch, pr.head_branch)
	file_diffs := parse_unified_diff(raw_diff)
	mut all_adds := 0
	mut all_dels := 0
	for fd in file_diffs {
		all_adds += fd.additions
		all_dels += fd.deletions
	}
	file_tree := build_pr_file_tree_rows(file_diffs)
	rcomments := app.get_pr_review_comments(pr.id)
	mut comments_by_key := map[string][]PrReviewCommentWithUser{}
	for rc in rcomments {
		u := app.get_user_by_id(rc.author_id) or { continue }
		key := '${rc.file_path}|${rc.side}|${rc.line_number}'
		comments_by_key[key] << PrReviewCommentWithUser{
			item: rc
			user: u
		}
	}
	can_comment := ctx.logged_in && pr.is_open()
	return $veb.html('templates/pull_files.html')
}

// POST /:username/:repo_name/pull/:id/comments
@['/:username/:repo_name/pull/:id/comments'; post]
pub fn (mut app App) handle_add_pr_comment(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	text := ctx.form['text']
	if validation.is_string_empty(text) {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.add_pr_comment(pr.id, ctx.user.id, text) or {
		ctx.error('Could not add comment')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.increment_pr_comments(pr.id) or { app.info(err.str()) }
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

// POST /:username/:repo_name/pull/:id/review
@['/:username/:repo_name/pull/:id/review'; post]
pub fn (mut app App) handle_submit_review(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	body := ctx.form['body']
	state_str := ctx.form['state']
	state := match state_str {
		'approved' { 1 }
		'changes_requested' { 2 }
		else { 0 }
	}

	review_id := app.add_pr_review(pr.id, ctx.user.id, state, body) or {
		ctx.error('Could not submit review')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}/files')
	}
	// Attach pending line comments from form (file_path|side|line — text)
	for key, val in ctx.form {
		if !key.starts_with('rc::') {
			continue
		}
		text := val.trim_space()
		if text == '' {
			continue
		}
		// rc::file::side::line
		parts := key[4..].split('::')
		if parts.len < 3 {
			continue
		}
		file_path := parts[0]
		side := parts[1]
		line_no := parts[2].int()
		app.add_pr_review_comment(pr.id, ctx.user.id, review_id, file_path, line_no, side, text) or {
			continue
		}
	}
	if body != '' {
		app.increment_pr_comments(pr.id) or {}
	}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

// POST /:username/:repo_name/pull/:id/line-comment
@['/:username/:repo_name/pull/:id/line-comment'; post]
pub fn (mut app App) handle_add_line_comment(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	file_path := ctx.form['file_path']
	side := ctx.form['side']
	line_no := ctx.form['line_number'].int()
	text := ctx.form['text']
	if validation.is_string_empty(text) || validation.is_string_empty(file_path) {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}/files')
	}
	app.add_pr_review_comment(pr.id, ctx.user.id, 0, file_path, line_no, side, text) or {
		ctx.error('Could not add line comment')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}/files')
	}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}/files#${file_path}-${side}-${line_no}')
}

// POST /:username/:repo_name/pull/:id/close
@['/:username/:repo_name/pull/:id/close'; post]
pub fn (mut app App) handle_close_pr(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	can_close := repo.user_id == ctx.user.id || pr.author_id == ctx.user.id
	if !can_close {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !pr.is_open() {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.set_pr_status(pr.id, .closed) or {
		ctx.error('Could not close PR')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.decrement_repo_open_prs(repo.id) or {}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

// POST /:username/:repo_name/pull/:id/reopen
@['/:username/:repo_name/pull/:id/reopen'; post]
pub fn (mut app App) handle_reopen_pr(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	can_reopen := repo.user_id == ctx.user.id || pr.author_id == ctx.user.id
	if !can_reopen {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !pr.is_closed() {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !app.contains_repo_branch(repo.id, pr.head_branch)
		|| !app.contains_repo_branch(repo.id, pr.base_branch) {
		ctx.error('Cannot reopen: head or base branch is missing')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.set_pr_status(pr.id, .open) or {
		ctx.error('Could not reopen PR')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.increment_repo_open_prs(repo.id) or {}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

// POST /:username/:repo_name/pull/:id/merge
@['/:username/:repo_name/pull/:id/merge'; post]
pub fn (mut app App) handle_merge_pr(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	mut repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	if repo.user_id != ctx.user.id {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !pr.is_open() {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	merge_message := 'Merge pull request #${pr.id} from ${pr.head_branch}\n\n${pr.title}'
	merge_hash := merge_branches_in_bare(repo, pr.base_branch, pr.head_branch, ctx.user.username,
		merge_message) or {
		ctx.error('Merge failed: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.set_pr_merged(pr.id, merge_hash) or {
		ctx.error('Merged but failed to update PR record')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.decrement_repo_open_prs(repo.id) or {}
	app.delete_repository_files_in_branch(repo.id, pr.base_branch) or {}
	app.update_repo_after_push(repo.id, pr.base_branch) or {
		app.warn('Failed to update repo after merge: ${err}')
	}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

// User-scoped PR list
@['/:username/pulls']
pub fn (mut app App) handle_get_user_pulls(mut ctx Context, username string) veb.Result {
	if !ctx.logged_in {
		return ctx.not_found()
	}
	exists, user := app.check_username(username)
	if !exists {
		return ctx.not_found()
	}
	mut prs := app.find_user_pull_requests(user.id)
	mut prs_with_repo := []PullRequest{}
	for mut pr in prs {
		r := app.find_repo_by_id(pr.repo_id) or { continue }
		pr.repo_author = r.user_name
		pr.repo_name = r.name
		prs_with_repo << pr
	}
	return $veb.html('templates/user_pulls.html')
}

// --- git helpers ---

// list_commits_between returns commits in head not in base.
fn (r Repo) list_commits_between(base string, head string) []Commit {
	if base == '' || head == '' {
		return []Commit{}
	}
	if !is_safe_ref(base) || !is_safe_ref(head) {
		return []Commit{}
	}
	out :=
		r.git('log ${base}..${head} --pretty=format:%h${log_field_separator}%aE${log_field_separator}%cD${log_field_separator}%s${log_field_separator}%aN')
	mut commits := []Commit{}
	for line in out.split_into_lines() {
		args := line.split(log_field_separator)
		if args.len < 5 {
			continue
		}
		date := time.parse_rfc2822(args[2]) or { time.now() }
		commits << Commit{
			hash:       args[0]
			author:     args[4]
			message:    args[3]
			created_at: int(date.unix())
			author_id:  0
		}
	}
	return commits
}

// diff_branches returns the unified diff between base and head.
fn (r Repo) diff_branches(base string, head string) string {
	if base == '' || head == '' {
		return ''
	}
	if !is_safe_ref(base) || !is_safe_ref(head) {
		return ''
	}
	return r.git('diff --no-color ${base}...${head}')
}

// merge_branches_in_bare performs a merge inside a bare repo using
// git merge-tree to compute the resulting tree, then commit-tree
// and update-ref to advance the base branch. Returns the merge commit hash.
fn merge_branches_in_bare(repo Repo, base string, head string, author string, message string) !string {
	if !is_safe_ref(base) || !is_safe_ref(head) {
		return error('invalid branch name')
	}
	git_dir := repo.git_dir
	base_sha := sh('git -C ${git_dir} rev-parse ${base}')
	head_sha := sh('git -C ${git_dir} rev-parse ${head}')
	if base_sha == '' || head_sha == '' {
		return error('branch refs missing')
	}
	// Try fast-forward first: if base is an ancestor of head, fast-forward.
	is_ancestor_result :=
		git.Git.exec_shell('git -C ${git_dir} merge-base --is-ancestor ${base_sha} ${head_sha}')
	if is_ancestor_result.exit_code == 0 {
		r := git.Git.exec_in_dir(git_dir, ['update-ref', 'refs/heads/${base}', head_sha])
		if r.exit_code != 0 {
			return error('fast-forward update-ref failed: ${r.output}')
		}
		return head_sha
	}
	// Use modern merge-tree --write-tree (Git >= 2.38).
	merge_result :=
		git.Git.exec_shell('git -C ${git_dir} merge-tree --write-tree ${base_sha} ${head_sha}')
	if merge_result.exit_code != 0 {
		return error('merge conflict — cannot auto-merge:\n${merge_result.output}')
	}
	tree_sha := merge_result.output.trim_space().split_into_lines().first()
	if tree_sha == '' {
		return error('failed to compute merge tree')
	}
	commit_sh := 'GIT_AUTHOR_NAME="${author}" GIT_AUTHOR_EMAIL="${author}@gitly" GIT_COMMITTER_NAME="${author}" GIT_COMMITTER_EMAIL="${author}@gitly" git -C ${git_dir} commit-tree ${tree_sha} -p ${base_sha} -p ${head_sha} -m "${shell_escape(message)}"'
	cr := git.Git.exec_shell(commit_sh)
	if cr.exit_code != 0 {
		return error('commit-tree failed: ${cr.output}')
	}
	commit_sha := cr.output.trim_space()
	ur := git.Git.exec_in_dir(git_dir, ['update-ref', 'refs/heads/${base}', commit_sha])
	if ur.exit_code != 0 {
		return error('update-ref failed: ${ur.output}')
	}
	return commit_sha
}

fn render_pr_diff_table(fd FileDiff, comments_by_key map[string][]PrReviewCommentWithUser, can_comment bool, lang Lang) veb.RawHtml {
	mut out := strings.new_builder(1024)
	out.write_string('<div class=pr-diff__table>')
	for hunk in fd.hunks {
		out.write_string(diff_hunk_header_html(hunk.header))
		for dline in hunk.lines {
			out.write_string(diff_line_row_html(fd.path, dline))
			if can_comment && dline.kind != 'context' {
				out.write_string(diff_comment_box_html(fd.path, dline, lang))
			}
			out.write_string(inline_comments_html(fd.path, dline, comments_by_key))
		}
	}
	out.write_string('</div>')
	return veb.RawHtml(out.str())
}

// inline_comments_html returns any line comments attached to a given diff line,
// matched on file_path, side, and line_number.
fn inline_comments_html(file_path string, dline DiffLine, comments_by_key map[string][]PrReviewCommentWithUser) string {
	mut side := ''
	mut line_no := 0
	if dline.kind == 'add' {
		side = 'new'
		line_no = dline.new_line
	} else if dline.kind == 'del' {
		side = 'old'
		line_no = dline.old_line
	} else {
		return ''
	}
	key := '${file_path}|${side}|${line_no}'
	list := comments_by_key[key] or { return '' }
	if list.len == 0 {
		return ''
	}
	mut out := ''
	for c in list {
		body := html_escape_text(c.item.text)
		username := html_escape_text(c.user.username)
		rel := html_escape_text(c.item.relative())
		out += '<p class=n><b>${username}</b> <i>commented ${rel}</i><br><s>${body}</s></p>'
	}
	return out
}

// is_safe_ref does a strict whitelist check for branch names used in shell.
fn is_safe_ref(name string) bool {
	if name == '' {
		return false
	}
	for ch in name {
		if !(ch.is_letter() || ch.is_digit() || ch in [`-`, `_`, `.`, `/`]) {
			return false
		}
	}
	if name.starts_with('-') || name.contains('..') {
		return false
	}
	return true
}

fn shell_escape(s string) string {
	mut out := ''
	backtick := u8(0x60)
	for ch in s {
		if ch == `"` || ch == `\\` || ch == `$` || ch == backtick {
			out += '\\'
		}
		out += ch.ascii_str()
	}
	return out
}
