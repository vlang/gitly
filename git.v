// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import strings
import encoding.base64

enum GitService {
	receive
	upload
	unknown
}

fn (s GitService) to_str() string {
	return match s {
		.receive { 'receive-pack' }
		.upload { 'upload-pack' }
		else { 'unknown' }
	}
}


fn (mut app App) auth() bool {
	user := app.get_user() or {
		println('bad auth!')
		return false
	}

	return app.repo_belongs_to(user.username, app.repo.name)
}

fn (mut app App) get_user() ?User {
	auth_head := app.get_header('Authorization')
	if auth_head.len == 0 {
		app.add_header('WWW-Authenticate', 'Basic realm="."')
		app.set_status(401, '401 Unauthorized')
		app.send_response_to_client(vweb.mime_types['.txt'], '')
	}
	println('GET USER $auth_head')
	auths := auth_head.split_by_whitespace()
	if auths.len != 2 || auths[0] != 'Basic' {
		return error('no basic auth and digit auth')
	}
	name, pwd := app.basic_auth_decode(auths[1]) or {
		return error('no basic auth and digit auth')
	}
	user := app.find_user_by_email(name) or {
		return error('user not found')
	}
	if !check_password(pwd, user.username, user.password) {
		return error('wrong password or email')
	}
	return user

}

fn (mut app App) basic_auth_decode(encoded string) ?(string, string) {
	s := base64.decode(encoded)

	tmp := s.split(':')
	auth := [tmp[0], tmp[1..].join(':')]
	return auth[0], auth[1]
}

// /vlang/info/refs?service=git-upload-pack
fn (mut app App) git_info() vweb.Result {
	app.info('/info/refs')
	app.info(app.req.method.str())
	// Get service type from the git request.
	// Receive (git push) or upload	(git pull)
	url := app.req.url
	service := if url.contains('?service=git-upload-pack') {
		GitService.upload
	} else if url.contains('?service=git-receive-pack') {
		GitService.receive
	} else {
		GitService.unknown
	}
	if service == .unknown {
		app.info('git: unknown info/refs service: $url')
		return vweb.Result{}
	}
	// Do auth here, we can communicate with the client only in inforefs
	if false && !app.repo.is_public {
		// Private repos are always closed
		// if !auth() {
		return app.not_found()
		// }
	} else {
		// public repo push
		if service == .receive {
			user := '' // get_user(c)
			app.info('info/refs user="$user"')
			if user == '' {
				// app.vweb.write_header(http.status_unauthorized)
				return app.not_found()
			}
		}
	}
	app.set_content_type('application/x-git-$service-advertisement')
	// hdrNocache(c.Writer)
	app.add_header('Cache-Control', 'no-cache')
	mut sb := strings.new_builder(100)
	sb.write(packet_write('# service=git-$service\n'))
	sb.write(packet_flush())
	refs := app.repo.git_advertise(service.to_str())
	app.info('refs = ')
	app.info(refs)
	sb.write(refs)
	return app.ok(sb.str())
}

['/:user/:repo/git-upload-pack']
fn (mut app App) git_upload_pack(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	if !app.repo.is_public {
		if !app.auth() {
			return app.not_found()
		}
	}
	body := app.req.data
	// TODO Handle gzip
	app.set_content_type('application/x-git-upload-pack-result')
	tmp := app.repo.git('upload-pack $body')
	println(tmp)
	return app.ok(tmp)
}

['/:user/:repo/git-receive-pack']
fn (mut app App) git_receive_pack(user string, repo string) vweb.Result {
	if !app.exists_user_repo(user, repo) {
		return app.not_found()
	}
	user := app.get_user() or {
		return app.not_found()
	}
	app.set_content_type('application/x-git-receive-pack-result')
	by := app.req.data
	refs :=
}

fn packet_flush() string {
	return '0000' // .bytes()
}

fn packet_write(str string) string {
	// s := strconv.format_int(i64(str.len+4), 16)
	mut s := (str.len + 4).hex()
	if s.len % 4 != 0 {
		s = strings.repeat(`0`, 4 - s.len % 4) + s
	}
	return s + str
}
