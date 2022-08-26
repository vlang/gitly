module main

import vweb
import validation
import api

['/api/v1/:user/:repo_name/issues/count']
fn (mut app App) handle_issues_count(username string, repo_name string) vweb.Result {
	// TODO: add auth checking module
	if !app.exists_user_repo(username, repo_name) {
		return app.not_found()
	}

	count := app.get_repo_issue_count(app.repo.id)

	return app.json(api.ApiIssueCount{
		success: true
		result: count
	})
}

['/:user/:repo/issues/new']
pub fn (mut app App) new_issue(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	if !app.logged_in {
		return app.not_found()
	}

	app.show_menu = true

	return $vweb.html()
}

['/:username/issues']
pub fn (mut app App) handle_get_user_issues(username string) vweb.Result {
	return app.user_issues(username, 0)
}

['/:user/:repo/issues'; post]
pub fn (mut app App) handle_add_repo_issue(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	// TODO: use captcha instead of user restrictions
	if !app.logged_in || (app.logged_in && app.user.posts_count >= posts_per_day) {
		return app.redirect_to_index()
	}

	title := app.form['title']
	text := app.form['text']

	is_title_empty := validation.is_string_empty(title)
	is_text_empty := validation.is_string_empty(text)

	if is_title_empty || is_text_empty {
		return app.redirect('/$user/$repo/issues/new')
	}

	app.increment_user_post(mut app.user)

	app.add_issue(app.repo.id, app.user.id, title, text)

	app.increment_repo_issues(app.repo.id)

	return app.redirect('/$user/$repo/issues')
}

['/:user/:repo/issues']
pub fn (mut app App) handle_get_repo_issues(user string, repo string) vweb.Result {
	return app.issues(user, repo, 0)
}

['/:user/:repo/issues/:page']
pub fn (mut app App) issues(user string, repo string, page int) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		app.not_found()
	}

	app.show_menu = true

	mut issues := app.find_repo_issues_as_page(app.repo.id, page)

	mut first := false
	mut last := false

	for index, issue in issues {
		issues[index].author_name = app.find_username_by_id(issue.author_id)
	}

	if app.repo.open_issues_count > commits_per_page {
		offset := page * commits_per_page
		delta := app.repo.open_issues_count - offset
		if delta > 0 {
			if delta == app.repo.open_issues_count && page == 0 {
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

['/:user/:repo/issue/:id']
pub fn (mut app App) issue(user string, repo string, id string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	app.show_menu = true

	mut issue := app.find_issue_by_id(id.int()) or { return app.not_found() }

	issue.author_name = app.find_username_by_id(issue.author_id)
	comments := app.get_all_issue_comments(issue.id)

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

	exists, u := app.check_username(username)

	if !exists {
		return app.not_found()
	}

	user := u

	mut issues := app.find_user_issues(user.id)
	mut first := false
	mut last := false

	for i, issue in issues {
		issues[i].author_name = username
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

	mut last_site := 0
	if page > 0 {
		last_site = page - 1
	}

	next_site := page + 1

	return $vweb.html()
}
