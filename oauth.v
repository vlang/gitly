// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main
import vweb
import json
import net.http

pub fn (mut app App) oauth() vweb.Result {
	code := app.vweb.query['code']
	if code == '' {
		app.info('Code is empty')
		return app.vweb.redirect('/')
	}
	req := OAuth_Request {
		client_id: app.oauth_client_id
		client_secret: app.oauth_client_secret
		code: code
	}
	d := json.encode(req)
	resp := http.post_json('https://github.com/login/oauth/access_token', d) or {
		app.info(err)
		return app.vweb.redirect('/')
	}
	mut token := resp.text.find_between('access_token=', '&')
	mut request := http.new_request('get', 'https://api.github.com/user', '') or {
		app.info(err)
		return app.vweb.redirect('/')
	}
	request.add_header('Authorization', 'token $token')
	user_js := request.do() or {
		app.info(err)
		return app.vweb.redirect('/')
	}
	if user_js.status_code != 200 {
		app.info(user_js.status_code.str())
		app.info(user_js.text)
		return app.vweb.text('Received $user_js.status_code error while attempting to contact GitHub')
	}
	gh_user := json.decode(GitHubUser, user_js.text) or {
		return app.vweb.redirect('/')
	}
	if gh_user.email.len == 0 {
		app.info('Email is empty')
		return app.vweb.redirect('/')
	}
	mut user := app.find_user_by_email(gh_user.email) or { User{} }
	if !user.is_github {
		app.add_user(gh_user.username, '', [gh_user.email], true)
		user = app.find_user_by_email(gh_user.email) or {
			return app.vweb.redirect('/')
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


