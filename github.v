// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
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
		return app.redirect_to_index()
	}

	csrf := app.get_cookie('csrf') or { return app.redirect_to_index() }
	if csrf != state || csrf == '' {
		app.security_log(
			user_id: app.user.id
			kind: .wrong_oauth_state
			arg1: 'csrf=$csrf'
			arg2: 'state=$state'
		)
		return app.redirect_to_index()
	}

	req := OAuthRequest{
		client_id: app.settings.oauth_client_id
		client_secret: app.settings.oauth_client_secret
		code: code
		state: csrf
	}
	d := json.encode(req)
	resp := http.post_json('https://github.com/login/oauth/access_token', d) or {
		app.info(err.msg())
		return app.redirect_to_index()
	}

	mut token := resp.text.find_between('access_token=', '&')
	mut request := http.new_request(.get, 'https://api.github.com/user', '') or {
		app.info(err.msg())
		return app.redirect_to_index()
	}
	request.add_header(.authorization, 'token $token')

	user_js := request.do() or {
		app.info(err.msg())
		return app.redirect_to_index()
	}

	if user_js.status_code != 200 {
		app.info(user_js.status_code.str())
		app.info(user_js.text)
		return app.text('Received $user_js.status_code error while attempting to contact GitHub')
	}
	gh_user := json.decode(GitHubUser, user_js.text) or { return app.redirect_to_index() }

	println('gh user:')
	println(user_js.text)
	println(gh_user)

	if gh_user.email.trim_space().len == 0 {
		app.security_log(user_id: app.user.id, kind: .empty_oauth_email, arg1: user_js.text)
		app.info('Email is empty')
		// return app.redirect_to_index()
	}

	mut user := app.find_user_by_github_username(gh_user.username) or { User{} }
	if !user.is_github {
		// Register a new user via github
		app.security_log(user_id: user.id, kind: .registered_via_github, arg1: user_js.text)

		app.add_user(gh_user.username, '', '', [gh_user.email], true, false)
		user = app.find_user_by_github_username(gh_user.username) or {
			return app.redirect_to_index()
		}
		app.update_user_avatar(gh_user.avatar, user.id)
	}

	client_ip := app.ip()

	app.auth_user(user, client_ip)
	app.security_log(user_id: user.id, kind: .logged_in_via_github, arg1: user_js.text)

	return app.redirect_to_index()
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
	repo_storage_path := app.settings.repo_storage_path
	sql app.db {
		update GitlySettings set oauth_client_id = oauth_client_id, oauth_client_secret = oauth_client_secret,
		repo_storage_path = repo_storage_path where id == id
	}
}
