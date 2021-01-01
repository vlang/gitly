// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import json
import net.http

struct OAuthRequest {
	client_id     string
	client_secret string
	code          string
	state         string
}

struct GitHubUser {
	username string [json: 'login']
	name     string
	email    string
	avatar   string [json: 'avatar_url']
}

pub fn (mut app App) oauth() vweb.Result {
	code := app.query['code']
	state := app.query['state']
	if code == '' {
		app.security_log(user_id: app.user.id, kind: .empty_oauth_code)
		app.info('Code is empty')
		return app.r_home()
	}
	csrf := app.get_cookie('csrf') or { return app.r_home() }
	if csrf != state || csrf == '' {
		app.security_log(
			user_id: app.user.id
			kind: .wrong_oauth_state
			arg1: 'csrf=$csrf'
			arg2: 'state=$state'
		)
		return app.r_home()
	}
	req := OAuthRequest{
		client_id: app.settings.oauth_client_id
		client_secret: app.settings.oauth_client_secret
		code: code
		state: csrf
	}
	d := json.encode(req)
	resp := http.post_json('https://github.com/login/oauth/access_token', d) or {
		app.info(err)
		return app.r_home()
	}
	mut token := resp.text.find_between('access_token=', '&')
	mut request := http.new_request(.get, 'https://api.github.com/user', '') or {
		app.info(err)
		return app.r_home()
	}
	request.add_header('Authorization', 'token $token')
	user_js := request.do() or {
		app.info(err)
		return app.r_home()
	}
	if user_js.status_code != 200 {
		app.info(user_js.status_code.str())
		app.info(user_js.text)
		return app.text('Received $user_js.status_code error while attempting to contact GitHub')
	}
	gh_user := json.decode(GitHubUser, user_js.text) or { return app.r_home() }
	println('gh user:')
	println(user_js.text)
	println(gh_user)
	if gh_user.email.trim_space().len == 0 {
		app.security_log(user_id: app.user.id, kind: .empty_oauth_email, arg1: user_js.text)
		app.info('Email is empty')
		// return app.r_home()
	}
	mut user := app.find_user_by_github_username(gh_user.username) or { User{} }
	if !user.is_github {
		// Register a new user via github
		app.security_log(user_id: user.id, kind: .registered_via_github, arg1: user_js.text)
		app.add_user(gh_user.username, '', [gh_user.email], true)
		user = app.find_user_by_github_username(gh_user.username) or { return app.r_home() }
		app.update_user_avatar(gh_user.avatar, user.id)
	}
	ip := app.client_ip(user.id.str()) or {
		println('Can not fetch ip')
		return app.r_home()
	}
	app.auth_user(user, ip)
	app.security_log(user_id: user.id, kind: .logged_in_via_github, arg1: user_js.text)
	return app.r_home()
}

fn (mut app App) load_settings() {
	data := sql app.db {
		select from GitlySettings limit 1
	}
	app.settings = data
}

fn (mut app App) update_settings() {
	id := app.settings.id
	oauth_client_id := app.settings.oauth_client_id
	oauth_client_secret := app.settings.oauth_client_secret
	only_gh_login := if app.settings.only_gh_login { 1 } else { 0 }
	repo_storage_path := app.settings.repo_storage_path
	sql app.db {
		update GitlySettings set oauth_client_id = oauth_client_id, oauth_client_secret = oauth_client_secret,
		repo_storage_path = repo_storage_path where id == id
	}
}
