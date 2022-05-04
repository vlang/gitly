module main

import vweb

['/:user/:repo/comments'; post]
pub fn (mut app App) handle_add_comment(user string, repo string, text string, issue_id string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	if text == '' || issue_id == '' || !app.logged_in {
		return app.redirect('/$user/$repo/issue/$issue_id')
	}

	app.add_issue_comment(app.user.id, issue_id.int(), text)

	// TODO: count comments
	app.increment_issue_comments(issue_id.int())

	return app.redirect('/$user/$repo/issue/$issue_id')
}
