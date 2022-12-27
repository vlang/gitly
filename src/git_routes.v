// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import git
import compress.deflate

['/:username/:repo_name/info/refs']
fn (mut app App) handle_git_info(username string, git_repo_name string) vweb.Result {
	repo_name := git.remove_git_extension_if_exists(git_repo_name)
	user := app.get_user_by_username(username) or { return app.not_found() }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id)
	service := extract_service_from_url(app.req.url)

	if repo.id == 0 {
		return app.not_found()
	}

	if service == .unknown {
		return app.not_found()
	}

	is_receive_service := service == .receive
	is_private_repo := !repo.is_public

	if is_receive_service || is_private_repo {
		app.check_git_http_access(username, repo_name) or { return app.ok('') }
	}

	refs := repo.git_advertise(service.str())
	git_response := build_git_service_response(service, refs)

	app.set_content_type('application/x-git-${service}-advertisement')
	app.set_no_cache_headers()

	return app.ok(git_response)
}

['/:user/:repo_name/git-upload-pack'; post]
fn (mut app App) handle_git_upload_pack(username string, git_repo_name string) vweb.Result {
	body := app.parse_body()
	repo_name := git.remove_git_extension_if_exists(git_repo_name)
	user := app.get_user_by_username(username) or { return app.not_found() }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id)
	is_private_repo := !repo.is_public

	if repo.id == 0 {
		return app.not_found()
	}

	if is_private_repo {
		app.check_git_http_access(username, repo_name) or { return app.ok('') }
	}

	git_response := repo.git_smart('upload-pack', body)

	app.set_git_content_type_headers(.upload)

	return app.ok(git_response)
}

['/:user/:repo_name/git-receive-pack'; post]
fn (mut app App) handle_git_receive_pack(username string, git_repo_name string) vweb.Result {
	body := app.parse_body()
	repo_name := git.remove_git_extension_if_exists(git_repo_name)
	user := app.get_user_by_username(username) or { return app.not_found() }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id)

	if repo.id == 0 {
		return app.not_found()
	}

	app.check_git_http_access(username, repo_name) or { return app.ok('') }

	git_response := repo.git_smart('receive-pack', body)

	branch_name := git.parse_branch_name_from_receive_upload(body) or {
		app.send_internal_error('Receive upload parsing error')

		return app.ok('')
	}

	app.update_repo_after_push(repo.id, branch_name)

	app.set_git_content_type_headers(.receive)

	return app.ok(git_response)
}

fn (mut app App) check_git_http_access(repository_owner string, repository_name string) ?bool {
	has_valid_auth_header := app.check_basic_authorization_header()

	if !has_valid_auth_header {
		app.set_authenticate_headers()
		app.send_unauthorized()
	}

	has_user_valid_credentials := app.check_user_credentials()

	if has_user_valid_credentials {
		username, _ := app.extract_user_credentials() or {
			app.send_unauthorized()
			return none
		}

		has_user_access := repository_owner == username

		if has_user_access {
			return true
		} else {
			app.send_not_found()
			return none
		}
	}

	app.send_unauthorized()
	return none
}

fn (mut app App) check_basic_authorization_header() bool {
	auth_header := app.get_header('Authorization')
	has_auth_header := auth_header.len > 0

	if !has_auth_header {
		return false
	}

	auth_header_parts := auth_header.fields()
	auth_type := auth_header_parts[0]
	is_basic_auth_type := auth_type == 'Basic'

	if auth_header_parts.len == 2 || is_basic_auth_type {
		return true
	}

	return false
}

fn (mut app App) extract_user_credentials() ?(string, string) {
	auth_header := app.get_header('Authorization')
	auth_header_parts := auth_header.fields()

	if auth_header_parts.len < 2 {
		return none
	}

	return decode_basic_auth(auth_header_parts[1])
}

fn (mut app App) check_user_credentials() bool {
	username, password := app.extract_user_credentials() or { return false }
	user := app.get_user_by_username(username) or { return false }

	return compare_password_with_hash(password, user.salt, user.password)
}

fn (mut app App) set_no_cache_headers() {
	app.add_header('Expires', 'Fri, 01 Jan 1980 00:00:00 GMT')
	app.add_header('Pragma', 'no-cache')
	app.add_header('Cache-Control', 'no-cache, max-age=0, must-revalidate')
}

fn (mut app App) set_authenticate_headers() {
	app.add_header('WWW-Authenticate', 'Basic realm="."')
}

fn (mut app App) set_git_content_type_headers(service GitService) {
	if service == .upload {
		app.set_content_type('application/x-git-upload-pack-result')
	} else if service == .receive {
		app.set_content_type('application/x-git-receive-pack-result')
	}
}

fn (mut app App) send_internal_error(custom_message string) {
	message := if custom_message == '' { 'Internal Server error' } else { custom_message }

	app.send_custom_error(500, message)
}

fn (mut app App) send_unauthorized() {
	app.send_custom_error(401, 'Unauthorized')
}

fn (mut app App) send_not_found() {
	app.send_custom_error(404, 'Not Found')
}

fn (mut app App) send_custom_error(code int, text string) {
	app.set_status(code, text)
	app.send_response_to_client(vweb.mime_types['.txt'], '')
}

fn (mut app App) parse_body() string {
	body := app.req.data

	if app.get_header('Content-Encoding') == 'gzip' {
		decompressed := deflate.decompress(body.bytes()[10..]) or {
			println(err)
			return body
		}

		return decompressed.bytestr()
	}

	return body
}
