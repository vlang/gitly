// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import git
import compress.deflate
import net.http

@['/:username/:repo_name/info/refs']
fn (mut app App) handle_git_info(username string, git_repo_name string) veb.Result {
	repo_name := git.remove_git_extension_if_exists(git_repo_name)
	user := app.get_user_by_username(username) or { return ctx.not_found() }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id) or { return ctx.not_found() }
	service := extract_service_from_url(ctx.req.url)

	if service == .unknown {
		return ctx.not_found()
	}

	is_receive_service := service == .receive
	is_private_repo := !repo.is_public

	if is_receive_service || is_private_repo {
		app.check_git_http_access(mut ctx, username, repo_name) or { return ctx.ok('') }
	}

	refs := repo.git_advertise(service.str())
	git_response := build_git_service_response(service, refs)

	ctx.set_content_type('application/x-git-${service}-advertisement')
	ctx.set_no_cache_headers()

	return ctx.ok(git_response)
}

@['/:user/:repo_name/git-upload-pack'; post]
fn (mut app App) handle_git_upload_pack(username string, git_repo_name string) veb.Result {
	body := ctx.parse_body()
	repo_name := git.remove_git_extension_if_exists(git_repo_name)
	user := app.get_user_by_username(username) or { return ctx.not_found() }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id) or { return ctx.not_found() }
	is_private_repo := !repo.is_public

	if is_private_repo {
		app.check_git_http_access(mut ctx, username, repo_name) or { return ctx.ok('') }
	}

	git_response := repo.git_smart('upload-pack', body)

	ctx.set_git_content_type_headers(.upload)

	return ctx.ok(git_response)
}

@['/:user/:repo_name/git-receive-pack'; post]
fn (mut app App) handle_git_receive_pack(username string, git_repo_name string) veb.Result {
	body := ctx.parse_body()
	repo_name := git.remove_git_extension_if_exists(git_repo_name)
	user := app.get_user_by_username(username) or { return ctx.not_found() }
	repo := app.find_repo_by_name_and_user_id(repo_name, user.id) or { return ctx.not_found() }

	app.check_git_http_access(mut ctx, username, repo_name) or { return ctx.ok('') }

	git_response := repo.git_smart('receive-pack', body)

	branch_name := git.parse_branch_name_from_receive_upload(body) or {
		ctx.send_internal_error('Receive upload parsing error')

		return ctx.ok('')
	}

	app.update_repo_after_push(repo.id, branch_name) or {
		ctx.send_internal_error('There was an error while updating the repo')

		return ctx.ok('')
	}

	ctx.set_git_content_type_headers(.receive)

	return ctx.ok(git_response)
}

fn (mut app App) check_git_http_access(mut ctx Context, repository_owner string, repository_name string) ?bool {
	has_valid_auth_header := ctx.check_basic_authorization_header()

	if !has_valid_auth_header {
		ctx.set_authenticate_headers()
		ctx.send_unauthorized()
	}

	has_user_valid_credentials := app.check_user_credentials(ctx)

	if has_user_valid_credentials {
		username, _ := ctx.extract_user_credentials() or {
			ctx.send_unauthorized()
			return none
		}

		has_user_access := repository_owner == username

		if has_user_access {
			return true
		} else {
			ctx.send_not_found()
			return none
		}
	}

	ctx.send_unauthorized()
	return none
}

fn (ctx &Context) check_basic_authorization_header() bool {
	auth_header := ctx.get_header(.authorization) or { return false }
	auth_header_parts := auth_header.fields()
	auth_type := auth_header_parts[0]
	is_basic_auth_type := auth_type == 'Basic'
	return auth_header_parts.len == 2 || is_basic_auth_type
}

fn (ctx &Context) extract_user_credentials() ?(string, string) {
	auth_header := ctx.get_header(.authorization) or { return none }
	auth_header_parts := auth_header.fields()

	if auth_header_parts.len < 2 {
		return none
	}

	return decode_basic_auth(auth_header_parts[1])
}

fn (mut app App) check_user_credentials(ctx &Context) bool {
	username, password := ctx.extract_user_credentials() or { return false }
	user := app.get_user_by_username(username) or { return false }

	return compare_password_with_hash(password, user.salt, user.password)
}

fn (mut app Context) set_no_cache_headers() {
	app.set_header(.expires, 'Fri, 01 Jan 1980 00:00:00 GMT')
	app.set_header(.pragma, 'no-cache')
	app.set_header(.cache_control, 'no-cache, max-age=0, must-revalidate')
}

fn (mut app Context) set_authenticate_headers() {
	app.set_header(.www_authenticate, 'Basic realm="."')
}

fn (mut app Context) set_git_content_type_headers(service GitService) {
	if service == .upload {
		app.set_content_type('application/x-git-upload-pack-result')
	} else if service == .receive {
		app.set_content_type('application/x-git-receive-pack-result')
	}
}

fn (mut app Context) send_internal_error(custom_message string) {
	message := if custom_message == '' { 'Internal Server error' } else { custom_message }

	app.send_custom_error(500, message)
}

fn (mut app Context) send_unauthorized() {
	app.send_custom_error(401, 'Unauthorized')
}

fn (mut app Context) send_not_found() {
	app.send_custom_error(404, 'Not Found')
}

fn (mut app Context) send_custom_error(code int, text string) {
	// app.set_status(code, text)
	app.res.set_status(unsafe { http.Status(code) })
	app.send_response_to_client(veb.mime_types['.txt'], '')
}

fn (mut app Context) parse_body() string {
	body := app.req.data

	if h := app.get_header(.content_encoding) {
		if h == 'gzip' {
			decompressed := deflate.decompress(body.bytes()[10..]) or {
				println(err)
				return body
			}

			return decompressed.bytestr()
		}
	}

	return body
}
