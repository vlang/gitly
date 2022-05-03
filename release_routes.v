module main

import vweb
import time

['/:user/:repo/releases']
pub fn (mut app App) releases(user_str string, repo string) vweb.Result {
	if !app.exists_user_repo(user_str, repo) {
		return app.not_found()
	}
	app.show_menu = true
	mut releases := []Release{}
	mut release := Release{}
	tags := app.get_all_repo_tags(app.repo.id)
	rels := app.find_repo_releases(app.repo.id)
	users := app.find_repo_registered_contributor(app.repo.id)
	for rel in rels {
		release.notes = rel.notes
		mut user_id := 0
		for tag in tags {
			if tag.id == rel.tag_id {
				release.tag_name = tag.name
				release.tag_hash = tag.hash
				release.date = time.unix(tag.date)
				user_id = tag.user_id
				break
			}
		}
		for user in users {
			if user.id == user_id {
				release.user = user.username
				break
			}
		}
		releases << release
	}
	return $vweb.html()
}
