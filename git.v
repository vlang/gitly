// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import strings

enum GitService {
	receive
	upload
	unknown
}

fn (g GitService) str() string {
	return match g {
		.receive { 'receive-pack' }
		.upload { 'upload-pack' }
		else { 'unknown' }
	}
}

['/:username/:repository/info/refs']
fn (mut app App) handle_git_info(username string, git_repository_name string) vweb.Result {
	repository_name := git_repository_name.trim_string_right('.git')
	url := app.req.url

	user := app.find_user_by_username(username) or { return app.not_found() }
	repository := app.find_repo_by_name(user.id, repository_name) or { return app.not_found() }

	// Get service type from the git request.
	// Receive (git push) or upload	(git pull)
	service := if url.contains('service=git-upload-pack') {
		GitService.upload
	} else if url.contains('service=git-receive-pack') {
		GitService.receive
	} else {
		GitService.unknown
	}

	if service == .unknown {
		return app.not_found()
	}

	app.set_content_type('application/x-git-$service-advertisement')
	// TODO: Add no cache headers
	app.add_header('Cache-Control', 'no-cache')

	service_name := service.str()

	mut git_response := strings.new_builder(100)
	git_response.write_string(packet_write('# service=git-$service_name\n'))
	git_response.write_string(packet_flush())

	refs := repository.git_advertise(service_name)

	git_response.write_string(refs)

	return app.ok(git_response.str())
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

fn packet_flush() string {
	return '0000'
}

fn packet_write(value string) string {
	packet_length := (value.len + 4).hex()

	return strings.repeat(`0`, 4 - packet_length.len) + packet_length + value
}
