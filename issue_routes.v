module main

import veb
import api
import time
import git

struct ItemWithUser[T] {
	item T
	user User
}

type IssueWithUser = ItemWithUser[Issue]

type CommentWithUser = ItemWithUser[Comment]

// GitLab-style issue management is intentionally broader than repository
// write access: Reporters, the author, and a current assignee can maintain an
// issue without receiving permission to push code. Callers must separately
// verify that the user can still read the target repository.
fn (app &App) issue_user_can_manage(user_id int, repo Repo, issue Issue) bool {
	if user_id <= 0 {
		return false
	}
	return issue.author_id == user_id || user_id in issue.assigned || app.repo_access_level(user_id, repo) >= project_access_reporter
}

fn (app &App) can_manage_issue(ctx Context, repo Repo, issue Issue) bool {
	return ctx.logged_in && app.can_read_repo(ctx, repo) && app.issue_user_can_manage(ctx.user.id, repo, issue)
}

@['/api/v1/:username/:repo_name/issues/count']
fn (mut app App) handle_issues_count(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	count := app.get_repo_issue_count(repo.id)
	return ctx.json(api.ApiIssueCount{
		success: true
		result:  count
	})
}

@['/:username/:repo_name/issues/new']
pub fn (mut app App) new_issue(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.not_found()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	ctx.set_page_title(['New issue', '${repo.user_name}/${repo.name}'])
	mut issue_template := ''
	for candidate in ['.gitea/ISSUE_TEMPLATE.md', '.github/ISSUE_TEMPLATE.md'] {
		res := git.Git.exec_in_dir(repo.git_dir, ['show', '${repo.primary_branch}:${candidate}'])
		if res.exit_code == 0 {
			issue_template = res.output
			break
		}
	}
	return $veb.html()
}

@['/:username/issues']
pub fn (mut app App) handle_get_user_issues(mut ctx Context, username string) veb.Result {
	return app.user_issues(mut ctx, username, 'created')
}

@['/:username/:repo_name/issues'; post]
pub fn (mut app App) handle_add_repo_issue(mut ctx Context, username string, repo_name string) veb.Result {
	// TODO: use captcha instead of user restrictions
	if !ctx.logged_in || user_reached_post_limit(ctx.user, int(time.now().unix())) {
		return ctx.redirect_to_index()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	title := ctx.form['title']
	text := ctx.form['text']
	if !valid_title(title) || !valid_body(text) {
		ctx.error('Issue title is missing or the description is too long')
		return ctx.redirect('/${username}/${repo_name}/issues/new')
	}
	app.add_issue(repo.id, ctx.user.id, title, text) or {
		app.info(err.str())
		return ctx.redirect('/${username}/${repo_name}/issues/new')
	}
	app.increment_user_post(mut ctx.user) or { app.info(err.str()) }
	app.sync_repo_open_issue_count(repo.id) or { app.info(err.str()) }
	app.dispatch_webhook(repo.id, 'issue', WebhookIssuePayload{
		action: 'opened'
		repo:   '${username}/${repo_name}'
		title:  title
		author: ctx.user.username
	})
	has_first_issue_activity := app.has_activity(ctx.user.id, 'first_issue')
	if !has_first_issue_activity {
		app.add_activity(ctx.user.id, 'first_issue') or { app.info(err.str()) }
	}
	return ctx.redirect('/${username}/${repo_name}/issues')
}

@['/:username/:repo_name/issues']
pub fn (mut app App) handle_get_repo_issues(mut ctx Context, username string, repo_name string) veb.Result {
	return app.issues(mut ctx, username, repo_name, '0')
}

@['/:username/:repo_name/issues/:page']
pub fn (mut app App) issues(mut ctx Context, username string, repo_name string, page string) veb.Result {
	mut repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.not_found()
	}
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	mut page_i := page.int()
	if page_i < 0 {
		page_i = 0
	}
	open_issue_count := app.get_repo_issue_count(repo.id)
	if repo.nr_open_issues != open_issue_count {
		app.sync_repo_open_issue_count(repo.id) or { app.info(err.str()) }
		repo.nr_open_issues = open_issue_count
	}
	current_state := normalize_issue_state(ctx.query['state'] or { 'open' })
	closed_issue_count := app.get_repo_closed_issue_count(repo.id)
	all_issue_count := open_issue_count + closed_issue_count
	open_tab_class := if current_state == 'open' {
		'issue-state-tab issue-state-tab--active'
	} else {
		'issue-state-tab'
	}
	closed_tab_class := if current_state == 'closed' {
		'issue-state-tab issue-state-tab--active'
	} else {
		'issue-state-tab'
	}
	all_tab_class := if current_state == 'all' {
		'issue-state-tab issue-state-tab--active'
	} else {
		'issue-state-tab'
	}
	issue_count := match current_state {
		'all' { all_issue_count }
		'closed' { closed_issue_count }
		else { open_issue_count }
	}
	page_count := calculate_pages(issue_count, commits_per_page)
	if page_i > page_count {
		if page_count == 0 {
			return ctx.redirect('/${repo.user_name}/${repo.name}/issues')
		}
		return ctx.redirect('/${repo.user_name}/${repo.name}/issues/${page_count}')
	}
	mut issues_with_users := []IssueWithUser{}
	mut issue := Issue{}
	mut user := User{}
	repo_issues := app.find_repo_issues_as_page_by_state(repo.id, page_i, current_state)
	mut i := 0
	for i = 0; i < repo_issues.len; i++ {
		issue = repo_issues[i]
		user = app.get_user_by_id(issue.author_id) or { placeholder_user(issue.author_id) }
		issue.labels = app.get_issue_labels(issue.id)
		issue.repo_author = repo.user_name
		issue.repo_name = repo.name
		issues_with_users << IssueWithUser{
			item: issue
			user: user
		}
	}
	show_repo_link := false
	first := page_i == 0
	last := page_i >= page_count
	prev_page, next_page := generate_prev_next_pages(page_i)
	ctx.set_page_title(['Issues', '${repo.user_name}/${repo.name}'])
	return $veb.html()
}

@['/:username/:repo_name/issue/:id']
pub fn (mut app App) issue(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	mut issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr {
		return ctx.not_found()
	}
	issue_author := app.get_user_by_id(issue.author_id) or { placeholder_user(issue.author_id) }
	assignees := app.find_issue_assignees(issue)
	issue.assigned = assignees.map(it.id)
	issue.labels = app.get_issue_labels(issue.id)
	planning := app.issue_planning_summary(issue)
	mut iterations := []Iteration{}
	if org := app.get_org_by_name(repo.user_name) {
		iterations = app.find_group_iterations(org.id)
	}
	can_manage := app.can_manage_issue(ctx, repo, issue)
	can_manage_assignees := can_manage
	mut assignable_users := []User{}
	if can_manage_assignees {
		for candidate in app.find_issue_assignable_users(repo) {
			if candidate.id !in issue.assigned {
				assignable_users << candidate
			}
		}
	}
	mut available_labels := []Label{}
	if can_manage {
		for label in app.list_repo_labels(repo.id) {
			if !issue.labels.any(it.id == label.id) {
				available_labels << label
			}
		}
	}
	ctx.set_page_title(['${issue.title} #${issue.id}', '${repo.user_name}/${repo.name}'])
	mut comments_with_users := []CommentWithUser{}
	mut comment := Comment{}
	mut comment_author := User{}
	issue_comments := app.get_all_issue_comments(issue.id)
	mut i := 0
	for i = 0; i < issue_comments.len; i++ {
		comment = issue_comments[i]
		comment_author = app.get_user_by_id(comment.author_id) or {
			placeholder_user(comment.author_id)
		}
		comments_with_users << CommentWithUser{
			item: comment
			user: comment_author
		}
	}
	return $veb.html()
}

@['/:username/:repo_name/issue/:id/edit']
pub fn (mut app App) edit_issue(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr || !app.can_manage_issue(ctx, repo, issue) {
		return ctx.not_found()
	}
	ctx.set_page_title(['Edit ${issue.title} #${issue.id}', '${repo.user_name}/${repo.name}'])
	return $veb.html('templates/edit_issue.html')
}

@['/:username/:repo_name/issue/:id/edit'; post]
pub fn (mut app App) handle_edit_issue(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr || !app.can_manage_issue(ctx, repo, issue) {
		return ctx.not_found()
	}
	title := ctx.form['title']
	body := ctx.form['text']
	app.update_issue(issue.id, title, body) or {
		ctx.error('Issue title is required and content must be within size limits')
		return app.edit_issue(mut ctx, username, repo_name, id)
	}
	app.dispatch_webhook(repo.id, 'issue', WebhookIssuePayload{
		action: 'updated'
		repo:   '${username}/${repo_name}'
		title:  title.trim_space()
		author: ctx.user.username
	})
	return ctx.redirect('/${username}/${repo_name}/issue/${issue.id}')
}

@['/:username/:repo_name/issue/:id/labels'; post]
pub fn (mut app App) handle_add_issue_label(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	label := app.find_repo_label_by_id(repo.id, ctx.form['label_id'].int()) or {
		return ctx.not_found()
	}
	if issue.repo_id != repo.id || issue.is_pr || !app.can_manage_issue(ctx, repo, issue) {
		return ctx.not_found()
	}
	app.add_issue_label(issue.id, label.id) or {
		ctx.error('Could not add that label')
		return app.issue(mut ctx, username, repo_name, id)
	}
	return ctx.redirect('/${username}/${repo_name}/issue/${issue.id}')
}

@['/:username/:repo_name/issue/:id/labels/:label_id/delete'; post]
pub fn (mut app App) handle_remove_issue_label(mut ctx Context, username string, repo_name string, id string, label_id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	label := app.find_repo_label_by_id(repo.id, label_id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr || !app.can_manage_issue(ctx, repo, issue) {
		return ctx.not_found()
	}
	app.remove_issue_label(issue.id, label.id) or {
		ctx.error('Could not remove that label')
		return app.issue(mut ctx, username, repo_name, id)
	}
	return ctx.redirect('/${username}/${repo_name}/issue/${issue.id}')
}

@['/:username/:repo_name/issue/:id/assign'; post]
pub fn (mut app App) handle_assign_issue(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr || !app.can_manage_issue(ctx, repo, issue) {
		return ctx.not_found()
	}
	app.assign_issue(issue.id, ctx.form['assignee_id'].int()) or {
		ctx.error('Could not assign that project member')
		return app.issue(mut ctx, username, repo_name, id)
	}
	return ctx.redirect('/${username}/${repo_name}/issue/${issue.id}')
}

@['/:username/:repo_name/issue/:id/unassign'; post]
pub fn (mut app App) handle_unassign_issue(mut ctx Context, username string, repo_name string, id string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr || !app.can_manage_issue(ctx, repo, issue) {
		return ctx.not_found()
	}
	app.unassign_issue(issue.id, ctx.form['assignee_id'].int()) or {
		ctx.error('Could not remove that assignee')
		return app.issue(mut ctx, username, repo_name, id)
	}
	return ctx.redirect('/${username}/${repo_name}/issue/${issue.id}')
}

@['/:username/:repo_name/issue/:id/close'; post]
pub fn (mut app App) handle_close_issue(mut ctx Context, username string, repo_name string, id string) veb.Result {
	return change_issue_status(mut app, mut ctx, username, repo_name, id, .closed)
}

@['/:username/:repo_name/issue/:id/reopen'; post]
pub fn (mut app App) handle_reopen_issue(mut ctx Context, username string, repo_name string, id string) veb.Result {
	return change_issue_status(mut app, mut ctx, username, repo_name, id, .open)
}

fn change_issue_status(mut app App, mut ctx Context, username string, repo_name string, id string, status IssueStatus) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr {
		return ctx.not_found()
	}
	if !app.issue_user_can_manage(ctx.user.id, repo, issue) {
		return ctx.not_found()
	}
	if issue.status == status {
		return ctx.redirect('/${username}/${repo_name}/issue/${issue.id}')
	}
	app.set_issue_status(issue.id, status) or {
		ctx.error('Could not update issue status')
		return app.issue(mut ctx, username, repo_name, id)
	}
	app.sync_repo_open_issue_count(repo.id) or { app.info(err.str()) }
	action := if status == .closed { 'closed' } else { 'reopened' }
	app.dispatch_webhook(repo.id, 'issue', WebhookIssuePayload{
		action: action
		repo:   '${username}/${repo_name}'
		title:  issue.title
		author: ctx.user.username
	})
	return ctx.redirect('/${username}/${repo_name}/issue/${issue.id}')
}

@['/:username/issues/:tab']
pub fn (mut app App) user_issues(mut ctx Context, username string, tab string) veb.Result {
	if !ctx.logged_in {
		return ctx.not_found()
	}
	if ctx.user.username != username {
		return ctx.not_found()
	}
	exists, user := app.check_username(username)
	if !exists {
		return ctx.not_found()
	}
	current_tab := if tab in ['assigned', 'created', 'mentioned', 'activity'] {
		tab
	} else {
		'created'
	}
	mut issues := match current_tab {
		'assigned' { app.find_user_assigned_issues(user.id) }
		'mentioned' { app.find_user_mentioned_issues(user.username) }
		'activity' { app.find_user_recent_issues(user.id) }
		else { app.find_user_issues(user.id) }
	}

	mut visible_issues := []Issue{cap: issues.len}
	for mut issue in issues {
		issue_repo := app.find_repo_by_id(issue.repo_id) or { continue }
		if !app.can_read_repo(ctx, issue_repo) {
			continue
		}
		issue.repo_author = issue_repo.user_name
		issue.repo_name = issue_repo.name
		issue.labels = app.get_issue_labels(issue.id)
		visible_issues << issue
	}
	mut issues_with_users := []IssueWithUser{}
	for issue in visible_issues {
		issue_author := app.get_user_by_id(issue.author_id) or { placeholder_user(issue.author_id) }
		issues_with_users << IssueWithUser{
			item: issue
			user: issue_author
		}
	}
	tab_assigned_class := if current_tab == 'assigned' {
		'user-issues-sidebar__item user-issues-sidebar__item--active'
	} else {
		'user-issues-sidebar__item'
	}
	tab_created_class := if current_tab == 'created' {
		'user-issues-sidebar__item user-issues-sidebar__item--active'
	} else {
		'user-issues-sidebar__item'
	}
	tab_mentioned_class := if current_tab == 'mentioned' {
		'user-issues-sidebar__item user-issues-sidebar__item--active'
	} else {
		'user-issues-sidebar__item'
	}
	tab_activity_class := if current_tab == 'activity' {
		'user-issues-sidebar__item user-issues-sidebar__item--active'
	} else {
		'user-issues-sidebar__item'
	}
	show_repo_link := true
	tab_title := match current_tab {
		'assigned' { 'Assigned issues' }
		'mentioned' { 'Mentioned issues' }
		'activity' { 'Issue activity' }
		else { 'Created issues' }
	}

	ctx.set_page_title([tab_title, user.username])
	return $veb.html()
}
