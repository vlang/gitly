module main

import vweb
import os

['/:username/:repo_name/tag/:tag/:format']
pub fn (mut app App) handle_download_tag_archive(username string, repo_name string, tag string, format string) vweb.Result {
	// access checking will be implemented in another module
	user := app.find_user_by_username(username) or { return app.not_found() }
	repo := app.find_repo_by_name(user.id, repo_name) or { return app.not_found() }

	archive_abs_path := os.abs_path(app.settings.archive_path)
	snapshot_format := if format == 'zip' { 'zip' } else { 'tar.gz' }
	snapshot_name := '${username}_${repo_name}_${tag}.$snapshot_format'
	archive_path := '$archive_abs_path/$snapshot_name'

	if format == 'zip' {
		repo.archive_tag(tag, archive_path, .zip)
	} else {
		repo.archive_tag(tag, archive_path, .tar)
	}

	archive_content := os.read_file(archive_path) or { return app.not_found() }

	return app.send_file(snapshot_name, archive_content)
}
