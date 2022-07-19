module main

import vweb

['/:user/:repo/branches']
pub fn (mut app App) branches(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	app.show_menu = true

	branches := app.get_all_repo_branches(app.repo.id)

	return $vweb.html()
}
