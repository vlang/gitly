module main

import vweb
import time

const (
	releases_per_page = 20
)

['/:username/:repo_name/releases']
pub fn (mut app App) releases_default(username string, repo_name string) vweb.Result {
	return app.releases(username, repo_name, 0)
}

['/:username/:repo_name/releases/:page']
pub fn (mut app App) releases(username string, repo_name string, page int) vweb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		return app.not_found()
	}

	repo_id := repo.id
	mut releases := []Release{}
	mut release := Release{}

	release_count := app.get_repo_release_count(repo_id)
	offset := releases_per_page * page
	page_count := calculate_pages(release_count, releases_per_page)
	is_first_page := check_first_page(page)
	is_last_page := check_last_page(release_count, offset, releases_per_page)
	prev_page, next_page := generate_prev_next_pages(page)

	tags := app.get_all_repo_tags(repo_id)
	rels := app.find_repo_releases_as_page(repo_id, offset)
	users := app.find_repo_registered_contributor(repo_id)

	download_archive_prefix := '/${username}/${repo_name}/tag'

	for rel in rels {
		release.notes = rel.notes
		mut user_id := 0

		for tag in tags {
			if tag.id == rel.tag_id {
				release.tag_name = tag.name
				release.tag_hash = tag.hash
				release.date = time.unix(tag.created_at)
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
