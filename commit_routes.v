module main

import vweb
import highlight
import time

['/:user/:repo/commits']
pub fn (mut app App) handle_commits(username string, repo string) vweb.Result {
	return app.commits(username, repo, 0)
}

['/:user/:repo/commits/:page']
pub fn (mut app App) commits(username string, repo string, page int) vweb.Result {
	if !app.exists_user_repo(username, repo) {
		return app.not_found()
	}

	app.show_menu = true

	mut commits := app.find_repo_commits_as_page(app.repo.id, page)

	// TODO: move to render logic
	mut b_author := false
	mut last := false
	mut first := false

	if app.repo.commits_count > commits_per_page {
		offset := page * commits_per_page
		delta := app.repo.commits_count - offset
		if delta > 0 {
			if delta == app.repo.commits_count && page == 0 {
				first = true
			} else {
				last = true
			}
		}
	} else {
		last = true
		first = true
	}

	mut last_site := 0
	if page > 0 {
		last_site = page - 1
	}
	next_site := page + 1
	mut msg := 'on'
	if b_author {
		msg = 'by'
	}

	mut d_commits := map[string][]Commit{}
	for commit in commits {
		date := time.unix(commit.created_at)
		day := date.day
		month := date.month
		year := date.year
		author := commit.author_id.str()
		date_s := '${day}.${month}.$year'
		if !b_author {
			if date_s !in d_commits {
				d_commits[date_s] = []Commit{}
			}
			d_commits[date_s] << commit
		} else {
			if author !in d_commits {
				d_commits[author] = []Commit{}
			}
			d_commits[author] << commit
		}
	}
	return $vweb.html()
}

['/:user/:repo/commit/:hash']
pub fn (mut app App) commit(username string, repository_name string, hash string) vweb.Result {
	user := app.find_user_by_username(username) or { return app.not_found() }
	app.repo = app.find_repo_by_name(user.id, repository_name) or { return app.not_found() }

	app.show_menu = true

	is_patch_request := hash.ends_with('.patch')

	if is_patch_request {
		commit_hash := hash.trim_string_right('.patch')
		patch := app.repo.get_commit_patch(commit_hash) or { return app.not_found() }

		return app.ok(patch)
	}

	patch_url := '/$username/$repository_name/commit/${hash}.patch'
	commit := app.find_repo_commit_by_hash(app.repo.id, hash)
	changes := commit.get_changes(app.repo)

	mut all_adds := 0
	mut all_dels := 0
	mut sources := map[string]vweb.RawHtml{}
	for change in changes {
		all_adds += change.additions
		all_dels += change.deletions
		src, _, _ := highlight.highlight_text(change.message, change.file, true)
		sources[change.file] = vweb.RawHtml(src)
	}

	return $vweb.html()
}
