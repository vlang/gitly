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
/*
['/:user/issues']
pub fn (mut app App) user_issues(user string) vweb.Result {}

['/:user/prs']
pub fn (mut app App) user_pullrequests(user string) vweb.Result {}

['/:user/settings']
pub fn (mut app App) user_settings(user string) vweb.Result {}*/
