// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import json

['/api/:user/:repo/issues']
pub fn (mut app App) api_issues(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.json('{}')
	}
	issues := app.find_repo_issues(sess.repo.id)
	// return c.json(json.encode(issues)) // TODO bring this back once autofree bug is fixed
	js := json.encode(issues)
	return c.json(js)
}

['/api/:user/:repo/commits']
pub fn (mut app App) api_commits(mut c vweb.Context, user string, repo string) vweb.Result {
	mut sess := app.get_session(mut c)
	if !app.exists_user_repo(mut c, user, repo) {
		return c.json('{}')
	}
	commits := app.find_repo_commits(sess.repo.id)
	// return c.json(json.encode(commits))
	js := json.encode(commits)
	return c.json(js)
}
