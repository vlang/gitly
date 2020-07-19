module main

import vweb

fn (mut app App) check_username(user string) (bool, User) {
	if user.len == 0 {
		return false, User{}
	}
	mut u := app.find_user_by_username(user) or {
		return false, User{}
	}
	u.b_avatar = u.avatar != ''
	if !u.b_avatar {
		u.avatar = u.username.bytes()[0].str()
	}
	return u.is_registered, u
}

['/:username']
pub fn (mut app App) user(username string) vweb.Result {
	println('user() name=$username')
	app.show_menu = false
	exists, u := app.check_username(username)
	if !exists {
		return app.vweb.not_found()
	}
	user := u
	return $vweb.html()
}


['/:username/repos']
pub fn (mut app App) user_repos(username string) vweb.Result {
	exists, u := app.check_username(username)
	if !exists {
		return app.vweb.not_found()
	}
	user := u
	repos := app.find_user_repos(user.id)
	return $vweb.html()
}

['/:username/issues']
pub fn (mut app App) user_issues2(username string) vweb.Result {
	return app.user_issues(username, '0')
}

['/:username/issues/:page_str']
pub fn (mut app App) user_issues(username, page_str string) vweb.Result {
	if !app.logged_in {
		return app.vweb.not_found()
	}
	if app.user.username != username {
		return app.vweb.not_found()
	}
	exists, u := app.check_username(username)
	if !exists {
		return app.vweb.not_found()
	}
	user := u
	page := if page_str.len >= 1 { page_str.int() } else { 0 }
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

/*
['/:user/prs']
pub fn (mut app App) user_pullrequests(user string) vweb.Result {}

['/:user/settings']
pub fn (mut app App) user_settings(user string) vweb.Result {}*/
