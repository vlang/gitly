module main

import vweb
import api

['/api/v1/:user/:repo_name/branches/count']
fn (mut app App) handle_branch_count(username string, repo_name string) vweb.Result {
	// TODO: add auth checking module
	if !app.exists_user_repo(username, repo_name) {
		return app.not_found()
	}

	count := app.get_count_repo_branches(app.repo.id)

	return app.json(api.ApiBranchCount{
		success: true
		result: count
	})
}

['/:user/:repo/branches']
pub fn (mut app App) branches(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	app.show_menu = true

	branches := app.get_all_repo_branches(app.repo.id)

	return $vweb.html()
}
