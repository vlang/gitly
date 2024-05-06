// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import json
import net.http
import veb.auth as oauth

struct GitHubUser {
	username string @[json: 'login']
	name     string
	email    string
	avatar   string @[json: 'avatar_url']
}

@['/oauth']
pub fn (mut app App) handle_oauth() vweb.Result {
	code := app.query['code']
	state := app.query['state']

	if code == '' {
		app.add_security_log(user_id: app.user.id, kind: .empty_oauth_code) or {
			app.info(err.str())
		}
		app.info('Code is empty')

		return app.redirect_to_index()
	}

	csrf := app.get_cookie('csrf') or { return app.redirect_to_index() }
	if csrf != state || csrf == '' {
		app.add_security_log(
			user_id: app.user.id
			kind: .wrong_oauth_state
			arg1: 'csrf=${csrf}'
			arg2: 'state=${state}'
		) or { app.info(err.str()) }

		return app.redirect_to_index()
	}

	oauth_request := oauth.Request{
		client_id: app.settings.oauth_client_id
		client_secret: app.settings.oauth_client_secret
		code: code
		state: csrf
	}

	js := json.encode(oauth_request)
	access_response := http.post_json('https://github.com/login/oauth/access_token', js) or {
		app.info(err.msg())

		return app.redirect_to_index()
	}

	mut token := access_response.body.find_between('access_token=', '&')
	mut request := http.new_request(.get, 'https://api.github.com/user', '')
	request.add_header(.authorization, 'token ${token}')

	user_response := request.do() or {
		app.info(err.msg())

		return app.redirect_to_index()
	}

	if user_response.status_code != 200 {
		app.info(user_response.status_code.str())
		app.info(user_response.body)
		return app.text('Received ${user_response.status_code} error while attempting to contact GitHub')
	}

	github_user := json.decode(GitHubUser, user_response.body) or { return app.redirect_to_index() }

	if github_user.email.trim_space().len == 0 {
		app.add_security_log(
			user_id: app.user.id
			kind: .empty_oauth_email
			arg1: user_response.body
		) or { app.info(err.str()) }
		app.info('Email is empty')
	}

	mut user := app.get_user_by_github_username(github_user.username) or { User{} }

	if !user.is_github {
		// Register a new user via github
		app.add_security_log(
			user_id: user.id
			kind: .registered_via_github
			arg1: user_response.body
		) or { app.info(err.str()) }

		app.register_user(github_user.username, '', '', [github_user.email], true, false) or {
			app.info(err.msg())
		}

		user = app.get_user_by_github_username(github_user.username) or {
			return app.redirect_to_index()
		}

		app.update_user_avatar(user.id, github_user.avatar) or { app.info(err.msg()) }
	}

	app.auth_user(user, app.ip()) or { app.info(err.msg()) }
	app.add_security_log(user_id: user.id, kind: .logged_in_via_github, arg1: user_response.body) or {
		app.info(err.str())
	}

	return app.redirect_to_index()
}
