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
		u.avatar = u.username.bytes()[0].str()
	}
	return u.is_registered, u
}

['/:username']
pub fn (mut app App) user(mut c vweb.Context, username string) vweb.Result {
	mut sess := app.get_session(mut c)
	println('user() name=$username')
	sess.show_menu = false
	exists, u := app.check_username(username)
	if !exists {
		return c.not_found()
	}
	user := u
	return $vweb.html()
}

['/:username/repos']
pub fn (mut app App) user_repos(mut c vweb.Context, username string) vweb.Result {
	mut sess := app.get_session(mut c)
	exists, u := app.check_username(username)
	if !exists {
		return c.not_found()
	}
	user := u
	mut repos := app.find_user_public_repos(user.id)
	if user.id == sess.user.id {
		repos = app.find_user_repos(user.id)
	}

	return $vweb.html()
}

['/:username/issues']
pub fn (mut app App) user_issues_0(mut c vweb.Context, username string) vweb.Result {
	mut sess := app.get_session(mut c)
	return app.user_issues(mut c, username, 0)
}

['/:username/issues/:page']
pub fn (mut app App) user_issues(mut c vweb.Context, username string, page int) vweb.Result {
	mut sess := app.get_session(mut c)
	if !sess.logged_in {
		return c.not_found()
	}
	if sess.user.username != username {
		return c.not_found()
	}
	exists, u := app.check_username(username)
	if !exists {
		return c.not_found()
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
pub fn (mut app App) user_settings(mut c vweb.Context, user string) vweb.Result {
	mut sess := app.get_session(mut c)
	return $vweb.html()
}

[post]
['/:user/settings']
pub fn (mut app App) update_user_settings(mut c vweb.Context, user string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !sess.logged_in || user != sess.user.username {
		return app.r_home(mut c)
	}
	name := if 'name' in c.form { c.form['name'] } else { '' }
	if name == '' {
		app.error('New name is empty')
		return app.user_settings(mut c, user)
	}
	if name == user {
		return app.user_settings(mut c, user)
	}
	if sess.user.nr_namechanges > max_namechanges {
		app.error('You can not change your username, limit reached')
		return app.user_settings(mut c, user)
	}
	if sess.user.last_namechange_time == 0
		|| sess.user.last_namechange_time + namechange_period <= time.now().unix {
		u := app.find_user_by_username(name) or { User{} }
		if u.id != 0 {
			app.error('Name already exists')
			return app.user_settings(mut c, user)
		}
		app.change_username(sess.user.id, name)
		app.inc_namechanges(sess.user.id)
		app.rename_user_dir(user, name)
		return c.redirect('/$name')
	}
	app.error('You need to wait until you can change the name again')
	return app.user_settings(mut c, user)
}
