// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import json

['/api/:user/:repo/issues']
pub fn (mut app App) api_issues(user, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.vweb.json('{}')
	}
	issues := app.find_repo_issues(app.repo.id)
	return app.vweb.json(json.encode(issues))
}

['/api/:user/:repo/commits']
pub fn (mut app App) api_commits(user, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.vweb.json('{}')
	}
	commits := app.find_repo_commits(app.repo.id)
	return app.vweb.json(json.encode(commits))
}
