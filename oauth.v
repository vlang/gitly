// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main
import vweb
import json
import net.http

pub fn (mut app App) oauth(parameter string) vweb.Result {
	println(parameter)
	code := parameter.all_after('code=')
	if code == '' {
		return app.vweb.not_found()
	}
	req := OAuth_Request {
		client_id: app.oauth_client_id
		client_secret: app.oauth_client_secret
		code: code
	}
	d := json.encode(req)
	resp := http.post_json('https://github.com/login/oauth/access_token', d) or {
		app.error(err)
		return app.vweb.not_found()
	}
	mut token := resp.text.find_between('access_token=', '&')
	mut request := http.new_request('get', 'https://api.github.com/user', '') or {
		app.error(err)
		return app.vweb.not_found()
	}
	request.add_header('Authorization', 'token $token')
	user_js := request.do() or {
		app.error(err)
		return app.vweb.not_found()
	}
	if user_js.status_code != 200 {
		app.error(user_js.status_code.str())
		app.error(user_js.text)
		return app.vweb.text('Received $user_js.status_code error while attempting to contact GitHub')
	}
	gh_user := json.decode(GitHubUser, user_js.text) or {
		return app.vweb.not_found()
	}
	mut user := app.find_user_by_email(gh_user.email) or { User{} }
	if !user.is_github {
		app.add_user(gh_user.username, '', [gh_user.email], true)
		user = app.find_user_by_email(gh_user.email) or {
			return app.vweb.not_found()
		}
		app.update_user_avatar(gh_user.avatar, user.id)
	}
	app.auth_user(user)
	return app.vweb.redirect('/')
}

fn (app &App) get_oauth_tokens_from_db() {
	data := sql app.db {
		select from GitlySettings limit 1
	}
	app.oauth_client_id = data.oauth_client_id
	app.oauth_client_secret = data.oauth_client_secret
	app.only_gh_login = data.only_gh_login
}


