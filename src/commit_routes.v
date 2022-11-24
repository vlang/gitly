module main

import vweb
import highlight
import time
import api

['/api/v1/:user/:repo_name/:branch_name/commits/count']
fn (mut app App) handle_commits_count(username string, repo_name string, branch_name string) vweb.Result {
	has_access := app.has_user_repo_read_access_by_repo_name(app.user.id, username, repo_name)

	if !has_access {
		return app.json_error('Not found')
	}

	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		return app.json_error('Not found')
	}

	branch := app.find_repo_branch_by_name(repo.id, branch_name)
	count := app.get_repo_commit_count(repo.id, branch.id)

	return app.json(api.ApiCommitCount{
		success: true
		result: count
	})
}

['/:username/:repo_name/:branch_name/commits/:page']
pub fn (mut app App) commits(username string, repo_name string, branch_name string, page int) vweb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		return app.not_found()
	}

	branch := app.find_repo_branch_by_name(repo.id, branch_name)
	commits_count := app.get_repo_commit_count(repo.id, branch.id)
	mut commits := app.find_repo_commits_as_page(repo.id, branch.id, page)

	// TODO: move to render logic
	offset := commits_per_page * page
	mut b_author := false
	mut first := page == 0
	mut last := (commits_count - offset) < commits_per_page

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
		date_s := '${day}.${month}.${year}'

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

['/:username/:repo_name/commit/:hash']
pub fn (mut app App) commit(username string, repo_name string, hash string) vweb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username)

	if repo.id == 0 {
		return app.not_found()
	}

	is_patch_request := hash.ends_with('.patch')

	if is_patch_request {
		commit_hash := hash.trim_string_right('.patch')
		patch := repo.get_commit_patch(commit_hash) or { return app.not_found() }

		return app.ok(patch)
	}

	patch_url := '/${username}/${repo_name}/commit/${hash}.patch'
	commit := app.find_repo_commit_by_hash(repo.id, hash)
	changes := commit.get_changes(repo)

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
