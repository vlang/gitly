module main

import vweb
import validation

['/:user/:repo/comments'; post]
pub fn (mut app App) handle_add_comment(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}

	text := app.form['text']
	issue_id := app.form['issue_id']

	is_text_empty := validation.is_string_empty(text)
	is_issue_id_empty := validation.is_string_empty(issue_id)

	if is_text_empty || is_issue_id_empty || !app.logged_in {
		app.error('Issue comment is not valid')

		return app.issue(user, repo, issue_id)
	}

	app.add_issue_comment(app.user.id, issue_id.int(), text)

	// TODO: count comments
	app.increment_issue_comments(issue_id.int())

	return app.redirect('/$user/$repo/issue/$issue_id')
}
