module main

import vweb

['/:user/:repo/comments'; post]
pub fn (mut app App) add_comment(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	text := app.form['text']
	issue_id := app.form['issue_id']

	if text == '' || issue_id == '' || !app.logged_in {
		return app.redirect('/$user/$repo/issue/$issue_id')
	}

	app.add_issue_comment(app.user.id, issue_id.int(), text)

	// TODO: count comments
	app.increment_issue_comments(issue_id.int())

	return app.redirect('/$user/$repo/issue/$issue_id')
}
