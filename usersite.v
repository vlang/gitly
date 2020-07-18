module main

import vweb

fn (mut app App) check_username(user string) (bool, User) {
	if user.len == 0 {
		return false, User{}
	}
	u := app.find_user_by_username(user) or {
		return false, User{}
	}
	return u.is_registered, u
}

['/:username']
pub fn (mut app App) user(username string) vweb.Result {
	println('user() name=$username')
	app.show_menu = false
	mut user := User{}
	if username.len != 0 {
		user = app.find_user_by_username(username) or {
			return app.vweb.not_found()
		}
	} else {
		return app.vweb.not_found()
	}
	user.b_avatar = user.avatar != ''
	if !user.b_avatar {
		user.avatar = user.username.bytes()[0].str()
	}
	repos := app.find_user_repos(user.id)
	return $vweb.html()
}


['/:user/repos']
pub fn (mut app App) user_repos(user string) vweb.Result {
	exists, u := app.check_username(user)
	if !exists {
		return app.vweb.not_found()
	}
	/*repos*/_ := app.find_user_repos(u.id)
	return app.vweb.text('TODO')
}
/*
['/:user/issues']
pub fn (mut app App) user_issues(user string) vweb.Result {}

['/:user/prs']
pub fn (mut app App) user_pullrequests(user string) vweb.Result {}

['/:user/settings']
pub fn (mut app App) user_settings(user string) vweb.Result {}*/
