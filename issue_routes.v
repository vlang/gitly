module main

import veb
import validation
import api

struct ItemWithUser[T] {
	item T
	user User
}

type IssueWithUser = ItemWithUser[Issue]
type CommentWithUser = ItemWithUser[Comment]

@['/api/v1/:username/:repo_name/issues/count']
fn (mut app App) handle_issues_count(username string, repo_name string) veb.Result {
	has_access := app.has_user_repo_read_access_by_repo_name(ctx, ctx.user.id, username, repo_name)
	if !has_access {
		return ctx.json_error('Not found')
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.json_error('Not found')
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
	ctx.set_page_title(['New issue', '${repo.user_name}/${repo.name}'])
	return $veb.html()
}

@['/:username/issues']
pub fn (mut app App) handle_get_user_issues(mut ctx Context, username string) veb.Result {
	return app.user_issues(mut ctx, username, 'created')
}

@['/:username/:repo_name/issues'; post]
pub fn (mut app App) handle_add_repo_issue(mut ctx Context, username string, repo_name string) veb.Result {
	// TODO: use captcha instead of user restrictions
	if !ctx.logged_in || (ctx.logged_in && ctx.user.posts_count >= posts_per_day) {
		return ctx.redirect_to_index()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	title := ctx.form['title']
	text := ctx.form['text']
	is_title_empty := validation.is_string_empty(title)
	is_text_empty := validation.is_string_empty(text)
	if is_title_empty || is_text_empty {
		return ctx.redirect('/${username}/${repo_name}/issues/new')
	}
	app.increment_user_post(mut ctx.user) or { app.info(err.str()) }
	app.add_issue(repo.id, ctx.user.id, title, text) or {
		app.info(err.str())
		return ctx.redirect('/${username}/${repo_name}/issues/new')
	}
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
	mut page_i := page.int()
	if page_i < 0 {
		page_i = 0
	}
	issue_count := app.get_repo_issue_count(repo.id)
	if repo.nr_open_issues != issue_count {
		app.sync_repo_open_issue_count(repo.id) or { app.info(err.str()) }
		repo.nr_open_issues = issue_count
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
	repo_issues := app.find_repo_issues_as_page(repo.id, page_i)
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
	issue := app.find_issue_by_id(id.int()) or { return ctx.not_found() }
	if issue.repo_id != repo.id || issue.is_pr {
		return ctx.not_found()
	}
	issue_author := app.get_user_by_id(issue.author_id) or { placeholder_user(issue.author_id) }
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
		'assigned' { []Issue{} }
		'mentioned' { app.find_user_mentioned_issues(user.username) }
		'activity' { app.find_user_recent_issues(user.id) }
		else { app.find_user_issues(user.id) }
	}

	mut issue_repo := Repo{}
	for mut issue in issues {
		issue_repo = app.find_repo_by_id(issue.repo_id) or { continue }
		issue.repo_author = issue_repo.user_name
		issue.repo_name = issue_repo.name
		issue.labels = app.get_issue_labels(issue.id)
	}
	mut issues_with_users := []IssueWithUser{}
	for issue in issues {
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
