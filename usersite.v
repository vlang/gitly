module main

import time
import vweb

fn (mut app App) check_username(user string) (bool, User) {
	if user.len == 0 {
		return false, User{}
	}
	mut u := app.find_user_by_username(user) or { return false, User{} }
	u.b_avatar = u.avatar != ''
	if !u.b_avatar {
		u.avatar = u.username[..1]
	}
	return u.is_registered, u
}

['/:username']
pub fn (mut app App) user(username string) vweb.Result {
	println('user() name=$username')
	app.show_menu = false
	exists, u := app.check_username(username)
	if !exists {
		return app.not_found()
	}
	user := u
	return $vweb.html()
}

['/:username/repos']
pub fn (mut app App) user_repos(username string) vweb.Result {
	exists, u := app.check_username(username)
	if !exists {
		return app.not_found()
	}
	user := u
	mut repos := app.find_user_public_repos(user.id)
	if user.id == app.user.id {
		repos = app.find_user_repos(user.id)
	}

	return $vweb.html()
}

['/:username/issues']
pub fn (mut app App) user_issues_0(username string) vweb.Result {
	return app.user_issues(username, 0)
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

/*
['/:user/prs']
pub fn (mut app App) user_pullrequests(user string) vweb.Result {}
*/
['/:user/settings']
pub fn (mut app App) user_settings(user string) vweb.Result {

	return $vweb.html()
}

[post]
['/:user/settings']
pub fn (mut app App) update_user_settings(user string) vweb.Result {
	if !app.logged_in || user != app.user.username {
		return app.r_home()
	}
	name := if 'name' in app.form { app.form['name'] } else { '' }
	if name == '' {
		app.error('New name is empty')
		return app.user_settings(user)
	}
	if name == user {
		return app.user_settings(user)
	}
	if app.user.nr_namechanges > max_namechanges {
		app.error('You can not change your username, limit reached')
		return app.user_settings(user)
	}
	if app.user.last_namechange_time == 0
		|| app.user.last_namechange_time + namechange_period <= time.now().unix {
		u := app.find_user_by_username(name) or { User{} }
		if u.id != 0 {
			app.error('Name already exists')
			return app.user_settings(user)
		}
		app.change_username(app.user.id, name)
		app.inc_namechanges(app.user.id)
		app.rename_user_dir(user, name)
		return app.redirect('/$name')
	}
	app.error('You need to wait until you can change the name again')
	return app.user_settings(user)
}
