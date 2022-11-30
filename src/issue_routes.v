module main

import vweb
import validation
import api

struct ItemWithUser[T] {
	item T
	user User
}

type IssueWithUser = ItemWithUser[Issue]
type CommentWithUser = ItemWithUser[Comment]

['/api/v1/:username/:repo_name/issues/count']
fn (mut app App) handle_issues_count(username string, repo_name string) vweb.Result {
	has_access := app.has_user_repo_read_access_by_repo_name(app.user.id, username, repo_name)

	if !has_access {
		return app.json_error('Not found')
	}

	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		return app.json_error('Not found')
	}

	count := app.get_repo_issue_count(repo.id)

	return app.json(api.ApiIssueCount{
		success: true
		result: count
	})
}

['/:username/:repo_name/issues/new']
pub fn (mut app App) new_issue(username string, repo_name string) vweb.Result {
	if !app.logged_in {
		return app.not_found()
	}

	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		return app.not_found()
	}

	return $vweb.html()
}

['/:username/issues']
pub fn (mut app App) handle_get_user_issues(username string) vweb.Result {
	return app.user_issues(username, 0)
}

['/:username/:repo_name/issues'; post]
pub fn (mut app App) handle_add_repo_issue(username string, repo_name string) vweb.Result {
	// TODO: use captcha instead of user restrictions
	if !app.logged_in || (app.logged_in && app.user.posts_count >= posts_per_day) {
		return app.redirect_to_index()
	}

	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		return app.not_found()
	}

	title := app.form['title']
	text := app.form['text']

	is_title_empty := validation.is_string_empty(title)
	is_text_empty := validation.is_string_empty(text)

	if is_title_empty || is_text_empty {
		return app.redirect('/${username}/${repo_name}/issues/new')
	}

	app.increment_user_post(mut app.user)

	app.add_issue(repo.id, app.user.id, title, text)

	app.increment_repo_issues(repo.id)

	has_first_issue_activity := app.has_activity(app.user.id, 'first_issue')

	if !has_first_issue_activity {
		app.add_activity(app.user.id, 'first_issue')
	}

	return app.redirect('/${username}/${repo_name}/issues')
}

['/:username/:repo_name/issues']
pub fn (mut app App) handle_get_repo_issues(username string, repo_name string) vweb.Result {
	return app.issues(username, repo_name, 0)
}

['/:username/:repo_name/issues/:page']
pub fn (mut app App) issues(username string, repo_name string, page int) vweb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		app.not_found()
	}

	mut issues_with_users := []IssueWithUser{}

	for issue in app.find_repo_issues_as_page(repo.id, page) {
		user := app.get_user_by_id(issue.author_id) or { continue }

		issues_with_users << IssueWithUser{
			item: issue
			user: user
		}
	}

	mut first := false
	mut last := false

	if repo.open_issues_count > commits_per_page {
		offset := page * commits_per_page
		delta := repo.open_issues_count - offset
		if delta > 0 {
			if delta == repo.open_issues_count && page == 0 {
				first = true
			} else {
				last = true
			}
		}
	} else {
		last = true
		first = true
	}

	mut last_site := 0

	if page > 0 {
		last_site = page - 1
	}

	next_site := page + 1

	return $vweb.html()
}

['/:username/:repo_name/issue/:id']
pub fn (mut app App) issue(username string, repo_name string, id string) vweb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		return app.not_found()
	}

	issue := app.find_issue_by_id(id.int()) or { return app.not_found() }
	issue_author := app.get_user_by_id(issue.author_id) or { return app.not_found() }

	mut comments_with_users := []CommentWithUser{}

	for comment in app.get_all_issue_comments(issue.id) {
		user := app.get_user_by_id(comment.author_id) or { continue }

		comments_with_users << CommentWithUser{
			item: comment
			user: user
		}
	}

	return $vweb.html()
}

['/:username/issues/:page']
pub fn (mut app App) user_issues(username string, page int) vweb.Result {
	if !app.logged_in {
		return app.not_found()
	}

	if app.user.username != username {
		return app.not_found()
	}

	exists, user := app.check_username(username)

	if !exists {
		return app.not_found()
	}

	mut issues := app.find_user_issues(user.id)
	mut first := false
	mut last := false

	for i, issue in issues {
		repo := app.find_repo_by_id(issue.repo_id)
		issues[i].repo_author = repo.user_name
		issues[i].repo_name = repo.name
	}

	if issues.len > commits_per_page {
		offset := page * commits_per_page
		delta := issues.len - offset
		if delta > 0 {
			if delta == issues.len && page == 0 {
				first = true
			} else {
				last = true
			}
		}
	} else {
		last = true
		first = true
	}

	mut issues_with_users := []IssueWithUser{}

	for issue in issues {
		issue_author := app.get_user_by_id(issue.author_id) or { continue }

		issues_with_users << IssueWithUser{
			item: issue
			user: issue_author
		}
	}

	mut last_site := 0
	if page > 0 {
		last_site = page - 1
	}

	next_site := page + 1

	return $vweb.html()
}
