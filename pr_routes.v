// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import validation
import git
import time
import strings
import os
import io.util
import rand

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

fn render_pr_file_tree(file_tree []PrFileTreeRow) veb.RawHtml {
	mut out := strings.new_builder(file_tree.len * 160)
	for row in file_tree {
		path := html_escape_text(row.path)
		name := html_escape_text(row.name)
		indent := row.indent_px
		if row.is_dir {
			out.write_string('<button type=button class="r d" q="${path}" style="--i:${indent}px" aria-expanded=true><b></b><span>${name}</span></button>')
		} else {
			status := row.status()
			out.write_string('<a class="r f" href="#diff-${path}" p="${path}" style="--i:${indent}px" title="${path}"><b></b><span>${name}</span><em>${status}</em><small><b>+${row.additions}</b><i>-${row.deletions}</i></small></a>')
		}
	}
	return veb.RawHtml(out.str())
}

fn (row PrFileTreeRow) status() string {
	if row.is_new {
		return 'A'
	}
	if row.is_deleted {
		return 'D'
	}
	if row.is_renamed {
		return 'R'
	}
	return 'M'
}

fn render_pr_file_diff(fd FileDiff, comments_by_key map[string][]PrReviewCommentWithUser, can_comment bool, lang Lang) veb.RawHtml {
	mut out := strings.new_builder(1024)
	path := html_escape_text(fd.path)
	out.write_string('<div class=pr-diff id="diff-${path}" data-diff-path="${path}"><div class=pr-diff__header><span class=pr-diff__path>')
	if fd.is_renamed && fd.old_path != fd.path {
		old_path := html_escape_text(fd.old_path)
		renamed_label := tr_text(lang, 'commit_file_renamed')
		out.write_string('<span class=pr-diff__tag>${renamed_label}</span><span class=pr-diff__oldpath>${old_path} &rarr;</span>')
	}
	out.write_string(path)
	if fd.is_new {
		new_label := tr_text(lang, 'commit_file_new')
		out.write_string('<span class="pr-diff__tag pr-diff__tag--new">${new_label}</span>')
	}
	if fd.is_deleted {
		deleted_label := tr_text(lang, 'commit_file_deleted')
		out.write_string('<span class="pr-diff__tag pr-diff__tag--deleted">${deleted_label}</span>')
	}
	out.write_string('</span><span class=pr-diff__counts><span class=pr-diff__add>+${fd.additions}</span><span class=pr-diff__del>-${fd.deletions}</span></span></div>')
	if fd.is_binary {
		binary_label := tr_text(lang, 'pr_binary_file')
		out.write_string('<div class=pr-diff__binary>${binary_label}</div>')
	} else {
		out.write_string(pr_diff_table_html(fd, comments_by_key, can_comment))
	}
	out.write_string('</div>')
	return veb.RawHtml(out.str())
}

fn tr_text(lang Lang, key string) string {
	return html_escape_text(veb.tr(lang.str(), key).trim_space())
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
						path: current_path
						name: part
						depth: idx
						indent_px: 10 + idx * 16
						is_dir: true
					}
				}
			}
		}
		rows << PrFileTreeRow{
			path: fd.path
			name: parts[parts.len - 1]
			depth: parts.len - 1
			indent_px: 10 + (parts.len - 1) * 16
			is_new: fd.is_new
			is_deleted: fd.is_deleted
			is_renamed: fd.is_renamed
			additions: fd.additions
			deletions: fd.deletions
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
			pr: pr
			user: author
		}
	}
	_ := app.get_repo_open_pr_count(repo.id)
	tab_open_class := if current_tab == 'open' { 'pr-tab pr-tab--active' } else { 'pr-tab' }
	tab_merged_class := if current_tab == 'merged' { 'pr-tab pr-tab--active' } else { 'pr-tab' }
	tab_closed_class := if current_tab == 'closed' { 'pr-tab pr-tab--active' } else { 'pr-tab' }
	tab_title := match current_tab {
		'closed' { 'Closed pull requests' }
		'merged' { 'Merged pull requests' }
		else { 'Open pull requests' }
	}

	ctx.set_page_title([tab_title, '${repo.user_name}/${repo.name}'])
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
	requested_head_repo_id := if 'head_repo' in ctx.query {
		ctx.query['head_repo'].int()
	} else {
		repo.id
	}
	head_repo := app.find_repo_by_id(requested_head_repo_id) or { repo }
	if !app.repos_share_fork_network(repo.id, head_repo.id)
		|| !app.user_has_repo_read_access(ctx.user.id, head_repo) {
		return ctx.not_found()
	}
	head_repo_id := head_repo.id
	head_branches := app.get_all_repo_branches(head_repo.id)
	mut commits := []Commit{}
	mut file_diffs := []FileDiff{}
	mut suggested_title := ''
	mut error_msg := ''
	mut has_compare := false
	if head != '' && (head_repo.id != repo.id || head != base) {
		has_compare = true
		if !app.contains_repo_branch(head_repo.id, head) || !app.contains_repo_branch(repo.id, base) {
			error_msg = 'Both base and compare branches must exist in this repository.'
			has_compare = false
		} else {
			mut compare_ref := head
			if head_repo.id != repo.id {
				compare_ref = 'refs/gitly-comparisons/${ctx.user.id}/${head_repo.id}/${rand.ulid()}'
				fetch_fork_branch_into(repo, head_repo, head, compare_ref) or {
					error_msg = err.str()
					has_compare = false
				}
				defer {
					git.Git.exec_in_dir(repo.git_dir, ['update-ref', '-d', compare_ref])
				}
			}
			commits = if has_compare {
				repo.list_commits_between(base, compare_ref)
			} else {
				[]Commit{}
			}
			raw_diff := if has_compare { repo.diff_branches(base, compare_ref) } else { '' }
			file_diffs = parse_unified_diff(raw_diff)
			if commits.len > 0 {
				suggested_title = commits[0].message
			}
		}
	}
	ctx.set_page_title(['New pull request', '${repo.user_name}/${repo.name}'])
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
	head_repo_id := ctx.form['head_repo_id'].int()
	head_repo := app.find_repo_by_id(head_repo_id) or { return ctx.not_found() }
	if !app.repos_share_fork_network(repo.id, head_repo.id)
		|| !app.user_has_repo_read_access(ctx.user.id, head_repo) {
		return ctx.not_found()
	}
	if !valid_title(title) || !valid_body(description) || validation.is_string_empty(head)
		|| validation.is_string_empty(base) {
		ctx.error('Title, head and base branches are required')
		return ctx.redirect('/${username}/${repo_name}/compare?base=${base}&head=${head}')
	}
	if head_repo.id == repo.id && head == base {
		ctx.error('Head and base must differ')
		return ctx.redirect('/${username}/${repo_name}/compare')
	}
	if !app.contains_repo_branch(head_repo.id, head) || !app.contains_repo_branch(repo.id, base) {
		ctx.error('Branches not found')
		return ctx.redirect('/${username}/${repo_name}/compare')
	}
	mut compare_ref := head
	if head_repo.id != repo.id {
		compare_ref = 'refs/gitly-comparisons/${ctx.user.id}/${head_repo.id}/${rand.ulid()}'
		fetch_fork_branch_into(repo, head_repo, head, compare_ref) or {
			ctx.error(err.str())
			return ctx.redirect('/${username}/${repo_name}/compare')
		}
		defer {
			git.Git.exec_in_dir(repo.git_dir, ['update-ref', '-d', compare_ref])
		}
	}
	commits := repo.list_commits_between(base, compare_ref)
	if commits.len == 0 {
		ctx.error('No commits between base and head')
		return ctx.redirect('/${username}/${repo_name}/compare?base=${base}&head=${head}')
	}
	stored_head_repo_id := if head_repo.id == repo.id { 0 } else { head_repo.id }
	if app.pull_request_exists_for_source(repo.id, stored_head_repo_id, head) {
		ctx.error('An open merge request already exists for this source branch')
		return ctx.redirect('/${username}/${repo_name}/compare')
	}
	pr_id := app.add_pull_request_from_repo(repo.id, stored_head_repo_id, ctx.user.id, title, description, head, base) or {
		ctx.error('Could not create pull request')
		return ctx.redirect('/${username}/${repo_name}/compare')
	}
	created_pr := app.find_pull_request_by_id(pr_id) or { return ctx.not_found() }
	app.refresh_cross_fork_pr_head(repo, created_pr) or {
		app.set_pr_status(pr_id, .closed) or {}
		ctx.error(err.str())
		return ctx.redirect('/${username}/${repo_name}/compare')
	}
	app.increment_repo_open_prs(repo.id) or { app.info(err.str()) }
	app.dispatch_webhook(repo.id, 'pr', WebhookPrPayload{
		action: 'opened'
		repo: '${username}/${repo_name}'
		number: pr_id
		title: title
		author: ctx.user.username
		head: head
		base: base
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
	head_repo := if pr.head_repo_id > 0 {
		app.find_repo_by_id(pr.head_repo_id) or { Repo{} }
	} else {
		repo
	}
	commits := repo.list_commits_between(pr.base_branch, pr.head_ref())
	comments := app.get_pr_comments(pr.id)
	reviews := app.get_pr_reviews(pr.id)
	rcomments := app.get_pr_review_comments(pr.id)
	mut timeline := []PrTimelineEntry{}
	for c in comments {
		u := app.get_user_by_id(c.author_id) or { continue }
		timeline << PrTimelineEntry{
			kind: 'comment'
			created_at: c.created_at
			user: u
			comment: c
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
			kind: 'review'
			created_at: r.created_at
			user: u
			review: r
			rcomments: r_comments
		}
	}
	timeline.sort(a.created_at < b.created_at)
	is_repo_owner := app.can_admin_repo(ctx, repo)
	current_head_oid := app.pull_request_head_oid(pr) or { '' }
	approvals := app.find_pull_request_approvals_for_head(pr, current_head_oid)
	approval_count := approvals.len
	required_approvals := app.required_approvals_for_branch(repo, pr.base_branch)
	approvals_satisfied := current_head_oid != ''
		&& app.approval_policies_satisfied_at_head(pr, repo, current_head_oid)
	has_approved := ctx.logged_in
		&& app.user_approved_pull_request_at_head(pr.id, ctx.user.id, current_head_oid)
	can_approve := ctx.logged_in && pr.is_open() && pr.author_id != ctx.user.id
		&& app.repo_access_level(ctx.user.id, repo) >= project_access_developer
	can_merge_branch := ctx.logged_in
		&& app.user_can_merge_branch(ctx.user.id, repo, pr.base_branch)
	can_merge := can_merge_branch && approvals_satisfied && pr.is_open()
	can_close := pr.is_open() && (is_repo_owner || pr.author_id == ctx.user.id)
	can_reopen := pr.is_closed() && (is_repo_owner || pr.author_id == ctx.user.id)
	ci_status := app.pull_request_ci_status(ctx.user.id, repo, pr) or { CiStatus{} }
	can_ai_fix := ctx.logged_in && app.can_ai_fix_pull_request(ctx.user.id, repo, pr)
	ctx.set_page_title(['${pr.title} #${pr.id}', '${repo.user_name}/${repo.name}'])
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
	raw_diff := repo.diff_branches(pr.base_branch, pr.head_ref())
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
	line_comment_placeholder := veb.tr(ctx.lang.str(), 'pr_line_comment_placeholder').trim_space()
	ctx.set_page_title(['${pr.title} #${pr.id}', 'Files changed', '${repo.user_name}/${repo.name}'])
	return $veb.html('templates/pull_files.html')
}

// POST /:username/:repo_name/pull/:id/comments
@['/:username/:repo_name/pull/:id/comments'; post]
pub fn (mut app App) handle_add_pr_comment(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	text := ctx.form['text']
	if !valid_comment(text) {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.add_pr_comment(pr.id, ctx.user.id, text) or {
		ctx.error('Could not add comment')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.increment_pr_comments(pr.id) or { app.info(err.str()) }
	app.dispatch_webhook(repo.id, 'comment', WebhookCommentPayload{
		action: 'created'
		repo: '${username}/${repo_name}'
		target: 'pr'
		number: pr.id
		author: ctx.user.username
		text: text
	})
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

// POST /:username/:repo_name/pull/:id/review
@['/:username/:repo_name/pull/:id/review'; post]
pub fn (mut app App) handle_submit_review(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	if !pr.is_open() {
		ctx.error('Reviews can only be submitted to open merge requests')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}/files')
	}
	body := ctx.form['body']
	state_str := ctx.form['state']
	if !valid_body(body) {
		ctx.error('Review body is too long')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}/files')
	}
	state := match state_str {
		'approved' { 1 }
		'changes_requested' { 2 }
		else { 0 }
	}
	if state == 1 && (pr.author_id == ctx.user.id
		|| app.repo_access_level(ctx.user.id, repo) < project_access_developer) {
		ctx.error('Only eligible Developers or Maintainers can approve this merge request')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}/files')
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
		if text == '' || !valid_comment(text) {
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
		if !is_valid_repo_file_path(file_path) || side !in ['old', 'new'] || line_no <= 0 {
			continue
		}
		app.add_pr_review_comment(pr.id, ctx.user.id, review_id, file_path, line_no, side, text) or {
			continue
		}
	}
	if body != '' {
		app.increment_pr_comments(pr.id) or {}
	}
	if state == 1 {
		app.approve_pull_request(pr.id, ctx.user.id) or { ctx.error('Could not record approval') }
	} else if state == 2 {
		app.revoke_pull_request_approval(pr.id, ctx.user.id) or {}
	}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

@['/:username/:repo_name/pull/:id/approve'; post]
pub fn (mut app App) handle_approve_pr(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id || !pr.is_open() || pr.author_id == ctx.user.id
		|| app.repo_access_level(ctx.user.id, repo) < project_access_developer {
		return ctx.not_found()
	}
	app.approve_pull_request(pr.id, ctx.user.id) or {
		ctx.error('Could not approve this merge request')
	}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

@['/:username/:repo_name/pull/:id/revoke-approval'; post]
pub fn (mut app App) handle_revoke_pr_approval(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id || !pr.is_open() {
		return ctx.not_found()
	}
	app.revoke_pull_request_approval(pr.id, ctx.user.id) or {
		ctx.error('Could not revoke approval')
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
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id || !pr.is_open() {
		return ctx.not_found()
	}
	file_path := ctx.form['file_path']
	side := ctx.form['side']
	line_no := ctx.form['line_number'].int()
	text := ctx.form['text']
	if !valid_comment(text) || !is_valid_repo_file_path(file_path) || line_no <= 0
		|| side !in ['old', 'new'] {
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
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	can_close := app.can_admin_repo(ctx, repo) || pr.author_id == ctx.user.id
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
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	can_reopen := app.can_admin_repo(ctx, repo) || pr.author_id == ctx.user.id
	if !can_reopen {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !pr.is_closed() {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !app.contains_repo_branch(repo.id, pr.base_branch)
		|| (pr.head_repo_id <= 0 && !app.contains_repo_branch(repo.id, pr.head_branch)) {
		ctx.error('Cannot reopen: head or base branch is missing')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.refresh_cross_fork_pr_head(repo, pr) or {
		ctx.error('Cannot reopen: ${err}')
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
	if !app.user_can_merge_branch(ctx.user.id, repo, pr.base_branch) {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !pr.is_open() {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.refresh_cross_fork_pr_head(repo, pr) or {
		ctx.error('Merge failed: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	head_oid := app.pull_request_head_oid(pr) or {
		ctx.error('Merge failed: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	// Refreshing a fork head can invalidate approvals. Gate the merge only after
	// that refresh so an approval for an older revision cannot authorize the new
	// source tip.
	if !app.pull_request_approvals_satisfied_at_head(pr, repo, head_oid) {
		ctx.error('Merge request approvals are still required')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.enforce_security_gate(repo, pr.base_branch, head_oid) or {
		ctx.error('Merge blocked by security policy: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if repo.require_signed_commits {
		base_oid := git_rev_parse(repo.git_dir, pr.base_branch) or {
			ctx.error('Merge failed: could not resolve the target branch')
			return ctx.redirect('/${username}/${repo_name}/pull/${id}')
		}
		app.verify_commit_range_for_policy(repo, base_oid, head_oid) or {
			ctx.error('Merge failed: ${err}')
			return ctx.redirect('/${username}/${repo_name}/pull/${id}')
		}
		if !git_is_ancestor(repo.git_dir, base_oid, head_oid) {
			ctx.error('Merge commits cannot be generated by Gitly while signed commits are required; rebase for a fast-forward merge')
			return ctx.redirect('/${username}/${repo_name}/pull/${id}')
		}
	}
	merge_message := 'Merge pull request #${pr.id} from ${pr.head_branch}\n\n${pr.title}'
	merge_hash := merge_branches_in_bare_at_head(repo, pr.base_branch, pr.head_ref(), head_oid, ctx.user.username, merge_message) or {
		ctx.error('Merge failed: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.complete_pr_merge(repo, pr, merge_hash) or {
		ctx.error('Merged but failed to update PR record')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

// POST /:username/:repo_name/pull/:id/squash
@['/:username/:repo_name/pull/:id/squash'; post]
pub fn (mut app App) handle_squash_pr(mut ctx Context, username string, repo_name string, id string) veb.Result {
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
	if !app.user_can_merge_branch(ctx.user.id, repo, pr.base_branch) {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !pr.is_open() {
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.refresh_cross_fork_pr_head(repo, pr) or {
		ctx.error('Squash merge failed: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	head_oid := app.pull_request_head_oid(pr) or {
		ctx.error('Squash merge failed: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if !app.pull_request_approvals_satisfied_at_head(pr, repo, head_oid) {
		ctx.error('Merge request approvals are still required')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.enforce_security_gate(repo, pr.base_branch, head_oid) or {
		ctx.error('Squash merge blocked by security policy: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	if repo.require_signed_commits {
		ctx.error('Squash merges cannot be generated by Gitly while signed commits are required')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	merge_message := 'Squash pull request #${pr.id} from ${pr.head_branch}\n\n${pr.title}'
	merge_hash := squash_branches_in_bare_at_head(repo, pr.base_branch, pr.head_ref(), head_oid, ctx.user.username, merge_message) or {
		ctx.error('Squash merge failed: ${err}')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	app.complete_pr_merge(repo, pr, merge_hash) or {
		ctx.error('Merged but failed to update PR record')
		return ctx.redirect('/${username}/${repo_name}/pull/${id}')
	}
	return ctx.redirect('/${username}/${repo_name}/pull/${id}')
}

fn (mut app App) complete_pr_merge(repo Repo, pr PullRequest, merge_hash string) ! {
	app.set_pr_merged(pr.id, merge_hash)!
	app.decrement_repo_open_prs(repo.id) or {}
	app.update_repo_branch_after_change(repo.id, pr.base_branch) or {
		app.warn('Failed to update repo after merge: ${err}')
	}
	app.delete_repository_files_in_branch(repo.id, pr.base_branch) or {}
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
		if !app.can_read_repo(ctx, r) {
			continue
		}
		pr.repo_author = r.user_name
		pr.repo_name = r.name
		prs_with_repo << pr
	}
	ctx.set_page_title(['Pull requests', user.username])
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
			hash: args[0]
			author: args[4]
			message: args[3]
			created_at: int(date.unix())
			author_id: 0
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

// merge_branches_in_bare_at_head performs a merge inside a bare repo using the
// exact reviewed head OID, then atomically verifies the head and base refs while
// publishing the result.
fn merge_branches_in_bare_at_head(repo Repo, base string, head_ref string, expected_head_oid string,
	author string, message string) !string {
	if !is_safe_ref(base) || !is_safe_ref(head_ref) || !is_full_git_oid(expected_head_oid) {
		return error('invalid branch name')
	}
	git_dir := repo.git_dir
	base_sha := git_rev_parse(git_dir, base)!
	current_head_oid := git_rev_parse(git_dir, head_ref)!
	if current_head_oid != expected_head_oid {
		return error('merge request head changed; approval is stale')
	}
	// Try fast-forward first: if base is an ancestor of head, fast-forward.
	if git_is_ancestor(git_dir, base_sha, expected_head_oid) {
		update_branch_ref_guarding_head(git_dir, base, expected_head_oid, base_sha, head_ref, expected_head_oid)!
		return expected_head_oid
	}
	// Use modern merge-tree --write-tree (Git >= 2.38).
	tree_sha := git_merge_tree(git_dir, base_sha, expected_head_oid)!
	commit_sha :=
		git_commit_tree(git_dir, tree_sha, [base_sha, expected_head_oid], author, message)!
	update_branch_ref_guarding_head(git_dir, base, commit_sha, base_sha, head_ref, expected_head_oid)!
	return commit_sha
}

// squash_branches_in_bare_at_head computes the merge result and writes one new
// commit on the base branch with only the old base commit as its parent.
fn squash_branches_in_bare_at_head(repo Repo, base string, head_ref string, expected_head_oid string,
	author string, message string) !string {
	if !is_safe_ref(base) || !is_safe_ref(head_ref) || !is_full_git_oid(expected_head_oid) {
		return error('invalid branch name')
	}
	git_dir := repo.git_dir
	base_sha := git_rev_parse(git_dir, base)!
	current_head_oid := git_rev_parse(git_dir, head_ref)!
	if current_head_oid != expected_head_oid {
		return error('merge request head changed; approval is stale')
	}
	tree_sha := git_merge_tree(git_dir, base_sha, expected_head_oid)!
	commit_sha := git_commit_tree(git_dir, tree_sha, [base_sha], author, message)!
	update_branch_ref_guarding_head(git_dir, base, commit_sha, base_sha, head_ref, expected_head_oid)!
	return commit_sha
}

fn git_rev_parse(git_dir string, ref_name string) !string {
	r := git.Git.exec_in_dir(git_dir, ['rev-parse', ref_name])
	if r.exit_code != 0 {
		return error('branch refs missing: ${r.output}')
	}
	sha := r.output.trim_space()
	if sha == '' {
		return error('branch refs missing')
	}
	return sha
}

fn git_is_ancestor(git_dir string, ancestor string, descendant string) bool {
	r := git.Git.exec_in_dir(git_dir, ['merge-base', '--is-ancestor', ancestor, descendant])
	return r.exit_code == 0
}

fn git_merge_tree(git_dir string, base_sha string, head_sha string) !string {
	r := git.Git.exec_in_dir(git_dir, ['merge-tree', '--write-tree', base_sha, head_sha])
	if r.exit_code != 0 {
		return error('merge conflict: cannot auto-merge:\n${r.output}')
	}
	lines := r.output.trim_space().split_into_lines()
	if lines.len == 0 || lines[0] == '' {
		return error('failed to compute merge tree')
	}
	return lines[0]
}

fn git_commit_tree(git_dir string, tree_sha string, parents []string, author string, message string) !string {
	mut args := ['commit-tree', tree_sha]
	for parent in parents {
		args << ['-p', parent]
	}
	args << ['-m', message]
	env := {
		'GIT_AUTHOR_NAME':     author
		'GIT_AUTHOR_EMAIL':    '${author}@gitly'
		'GIT_COMMITTER_NAME':  author
		'GIT_COMMITTER_EMAIL': '${author}@gitly'
	}
	r := git.Git.exec_in_dir_with_env(git_dir, args, env)
	if r.exit_code != 0 {
		return error('commit-tree failed: ${r.output}')
	}
	commit_sha := r.output.trim_space()
	if commit_sha == '' {
		return error('commit-tree produced no commit')
	}
	return commit_sha
}

fn update_git_ref_expected(git_dir string, ref_name string, new_sha string, expected_old_sha string) ! {
	if !ref_name.starts_with('refs/') || ref_name.contains_any('\x00\r\n ') || new_sha == ''
		|| expected_old_sha == '' {
		return error('invalid ref update')
	}
	r := git.Git.exec_in_dir(git_dir, ['update-ref', ref_name, new_sha, expected_old_sha])
	if r.exit_code != 0 {
		return error('update-ref failed: ${r.output}')
	}
}

fn zero_oid_like(oid string) !string {
	if oid.len !in [40, 64] {
		return error('invalid object id')
	}
	return '0'.repeat(oid.len)
}

// update_branch_ref_guarding_head verifies the reviewed source ref and the
// destination base while advancing the base in one Git reference transaction.
// A push racing between approval gating and publication therefore aborts the
// whole update instead of changing which commit gets merged.
fn update_branch_ref_guarding_head(git_dir string, base_branch string, commit_sha string,
	expected_base_oid string, head string, expected_head_oid string) ! {
	if !is_safe_ref(base_branch) || !is_safe_ref(head) || !is_full_git_oid(commit_sha)
		|| !is_full_git_oid(expected_base_oid) || !is_full_git_oid(expected_head_oid) {
		return error('invalid ref transaction')
	}
	base_ref := 'refs/heads/${base_branch}'
	head_ref := if head.starts_with('refs/') { head } else { 'refs/heads/${head}' }
	if head_ref == base_ref {
		return error('merge request head and base refs must differ')
	}
	mut input, input_path := util.temp_file(pattern: 'gitly-update-ref-*.stdin')!
	input.close()
	defer {
		os.rm(input_path) or {}
	}
	transaction := 'verify ${head_ref} ${expected_head_oid}\n' + 'update ${base_ref} ${commit_sha} ${expected_base_oid}\n'
	os.write_file(input_path, transaction) or {
		return error('could not write ref transaction: ${err}')
	}

	mut process := os.new_process('git')
	process.set_args(['-C', git_dir, 'update-ref', '--stdin'])
	process.set_redirect_stdio_merged()
	process.set_stdin_path(input_path)
	process.run()
	output := process.stdout_slurp()
	process.wait()
	exit_code := process.code
	process.close()
	if exit_code != 0 {
		return error('source or target branch changed during merge: ${output.trim_space()}')
	}
}

fn pr_diff_table_html(fd FileDiff, comments_by_key map[string][]PrReviewCommentWithUser, can_comment bool) string {
	mut out := strings.new_builder(1024)
	out.write_string('<div class=pr-diff__table>')
	for hunk in fd.hunks {
		out.write_string(diff_hunk_header_html(hunk.header))
		for dline in hunk.lines {
			attrs := if can_comment && dline.kind != 'context' {
				' s=${dline.compact_side()} l=${dline.effective_line()}'
			} else {
				''
			}
			out.write_string(diff_line_row_html_with_attrs(fd.path, dline, attrs))
			out.write_string(inline_comments_html(fd.path, dline, comments_by_key))
		}
	}
	out.write_string('</div>')
	return out.str()
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
	if name == '' || name.len > 255 || name.starts_with('/') || name.ends_with('/')
		|| name.starts_with('.') || name.ends_with('.') || name.ends_with('.lock')
		|| name.contains('//') || name.contains('..') || name.contains('@{') {
		return false
	}
	for ch in name {
		if !(ch.is_letter() || ch.is_digit() || ch in [`-`, `_`, `.`, `/`]) {
			return false
		}
	}
	if name.starts_with('-') {
		return false
	}
	return true
}

fn is_valid_commit_hash(hash string) bool {
	if hash.len < 4 || hash.len > 64 {
		return false
	}
	for ch in hash.to_lower() {
		if !ch.is_digit() && (ch < `a` || ch > `f`) {
			return false
		}
	}
	return true
}
