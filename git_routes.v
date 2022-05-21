// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb

['/:username/:repository/info/refs']
fn (mut app App) handle_git_info(username string, git_repository_name string) vweb.Result {
	repository_name := git_repository_name.trim_string_right('.git')
	user := app.find_user_by_username(username) or { return app.not_found() }
	repository := app.find_repo_by_name(user.id, repository_name) or { return app.not_found() }
	service := extract_service_from_url(app.req.url)

	if service == .unknown {
		return app.not_found()
	}

	refs := repository.git_advertise(service.str())
	response := build_git_service_response(service, refs)

	app.set_content_type('application/x-git-$service-advertisement')
	app.set_no_cache_headers()

	return app.ok(response)
}

['/:user/:repo/git-upload-pack'; post]
fn (mut app App) handle_git_upload_pack(username string, git_repository_name string) vweb.Result {
	repository_name := git_repository_name.trim_string_right('.git')

	user := app.find_user_by_username(username) or { return app.not_found() }
	repository := app.find_repo_by_name(user.id, repository_name) or { return app.not_found() }

	body := app.req.data
	git_response := repository.git_smart('upload-pack', body)

	app.set_content_type('application/x-git-upload-pack-result')

	return app.ok(git_response)
}

fn (mut app App) set_no_cache_headers() {
	app.add_header('Expires', 'Fri, 01 Jan 1980 00:00:00 GMT')
	app.add_header('Pragma', 'no-cache')
	app.add_header('Cache-Control', 'no-cache, max-age=0, must-revalidate')
}
