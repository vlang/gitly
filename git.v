// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
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

fn (mut app App) git_auth() bool {
	user, ok := app.get_user()
	if !ok {
		return false
	}
	return true
	// if user.id == 0 || !app.repo_belongs_to(user) 
}

fn (mut app App) get_user() (User, bool) {
	auth_head := app.get_header('Authorization')
	if auth_head.len == 0 {
		app.add_header('WWW-Authenticate', 'Basic realm="."')
		app.set_status(401, 'Unauthorized')
		app.send_response_to_client(vweb.mime_types['.txt'], '')
	}
	auths := auth_head.split_by_whitespace()
	if auths.len != 2 || auths[0] != 'Basic' {
		return User{}, true
	}
	name, pwd := basic_auth_decode(auths[1])
	user := app.find_user_by_email(name) or {
		return User{}, false
	}
	if !check_password(pwd, user.username, user.password) {
		return User{}, false
	}
	return user, true
}

// /:user/:repo/info/refs?service=git-upload-pack
['/:user/:repo/info/refs']
fn (mut app App) git_info(user_str string, repo string) vweb.Result {
	if !app.user_can_access_repo(user_str, repo) {
		return app.not_found()
	}

	app.info('/info/refs')
	app.info(app.req.method.str())
	
	service := if app.query['service'] == 'git-upload-pack' {
		GitService.upload
	} else if app.query['service'] == 'git-receive-pack' {
		GitService.receive
	} else {
		GitService.unknown
	}

	if service == .unknown {
		return app.not_found()
	}

	// Do auth here, we can communicate with the client only in inforefs
	if !app.repo.is_public {
		// Private repos are always closed
		if !app.git_auth() {
			return app.not_found()
		}
	} else {
		// public repo push
		if service == .receive {
			user, ok := app.get_user()
			app.info('info/refs user="$user"')
			if user.id == 0 {
				return app.server_error(401)
			}
		}
	}
	app.set_content_type('application/x-git-$service-advertisement')
	// hdrNocache(c.Writer)
	app.add_header('Cache-Control', 'no-cache')
	mut sb := strings.new_builder(100)
	sb.write_string(packet_write('# service=git-$service\n'))
	sb.write_string(packet_flush())
	refs := app.repo.git_advertise(service.to_str())
	app.info('refs = ')
	app.info(refs)
	sb.write_string(refs)
	return app.ok(sb.str())
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

fn basic_auth_decode(encoded string) (string, string) {
	s := string(base64.decode(encoded))
	tmp := s.split(':')
	auth := [tmp[0], tmp[1..].join(':')]
	return auth[0], auth[1]
}
