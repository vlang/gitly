// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import json

// TODO rename all these methods from '/api_issues' to `/api/issues'
pub fn (mut app App) api_issues() vweb.Result {
	issues := app.find_repo_issues(app.repo.id)
	return app.vweb.json(json.encode(issues))
}

pub fn (mut app App) api_commits() vweb.Result {
	commits := app.find_repo_commits(app.repo.id)
	return app.vweb.json(json.encode(commits))
}
