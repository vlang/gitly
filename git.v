// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import strings
import encoding.base64
import io
import os
import strconv
import time

enum GitService {
	receive
	upload
	unknown
}

struct Push {
	old string
	new string
	ref string
mut:
	branch string
	user_id int
	repo_id int
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
	if user.id == 0 || user.id != app.repo.user_id || !ok {
		return false
	}
	return true
}

fn (mut app App) get_user() (User, bool) {
	auth_head := app.get_header('Authorization')
	if auth_head.len == 0 {
		app.add_header('WWW-Authenticate', 'Basic realm="."')
		app.set_status(401, 'Unauthorized')
		app.send_response_to_client(vweb.mime_types['.txt'], '')
	}
	auths := auth_head.fields()
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
		return app.not_found() // TODO
		// return app.info('git: unknown info/refs service: $url')
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
			user, _ := app.get_user()
			app.info('info/refs user="$user"')
			if user.id == 0 {
				return app.server_error(401)
			}
		}
	}
	app.set_content_type('application/x-git-$service-advertisement')
	app.hdr_nocache()
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

['/:user/:repo/git-upload-pack']
fn (mut app App) git_upload_pack(user_str string, repo string) vweb.Result {
	if !app.user_can_access_repo(user_str, repo) {
		return app.not_found()
	}
	mut body := app.req.data
	if app.get_header('Content-Encoding') == 'gzip' {
		r := os.execute('echo "$body" | gzip -f')
		if r.exit_code != 0 {
			eprintln('Something went wrong with gzip. Error code $r.exit_code')
			return app.not_found()
		}
		body = r.output
	}
	app.set_content_type('application/x-git-upload-pack-result')
	res := app.repo.git_smart('upload-pack', body)
	return app.ok(res)
}

['/:user/:repo/git-receive-pack']
fn (mut app App) git_receive_pack(user_str string, repo string) vweb.Result {
	user, _ := app.get_user()

	app.info('PUSH $user')
	if user.id == 0 {
		return app.server_error(401)
	}
	app.set_content_type('application/x-git-receive-pack-result')
	by := app.req.data
	mut refs := parse_binary_push(make_reader(by.bytes())) or {
		eprintln('parse binary push failed')
		return app.not_found()
	}
	for i in 0..refs.len {
		refs[i].user_id = user.id
		refs[i].repo_id = app.repo.id
		handle_ref_push_before(mut refs[i])
	}

	return app.ok('')
}

fn packet_flush() string {
	return '0000' // .bytes()
}

fn packet_write(str string) string {
	mut s := strconv.format_int(i64(str.len+4), 16)
	//mut s := (str.len + 4).hex()
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

fn (mut app App) hdr_nocache() {
	app.add_header('Expires', 'Fri, 01 Jan 1980 00:00:00 GMT')
	app.add_header('Pragma', 'no-cache')
	app.add_header('Cache-Control', 'no-cache, max-age=0, must-revalidate')
}

fn parse_binary_push(input io.Reader) ?[]&Push {
	mut head := []byte{len: 4, init: 0}
	mut n := 0
	mut pushes := []&Push{}
	for {
		n = input.read(mut head) or {
			return err
		}
		if n < 4 {
			println('N=$n')
			break
		}
		if head[0] == `0` && head[1] == `0` {
			size := strconv.parse_int(head[2..4].str(), 16, 32)
			if size == 0 {
				break
			}
			mut line := []byte{len: int(size)}
			n = input.read(mut line) or {
				return err
			}
			if n < int(size) {
				println('did not read enought bytes: expected $size got $n')
				break
			}
			idx := line.str().index_any('\000')
			if idx > -1 {
				line = line[..idx]
			}

			fields := line.str().fields()
			println('\n\n GIT VALS=$fields')
			if fields.len >= 3 {
				pushes << &Push{
					old: fields[0]
					new: fields[1]
					ref: fields[2]
				}
			}
		} else {
			break
		}
	}
	return pushes
}

fn handle_ref_push_before(mut push &Push) {
	mut branch := 'master'
	println('handle before ${time.now().unix}')
	pos := push.ref.index_any('refs/heads/')
	if pos == 0 {
		branch = push.ref[pos+11..]
	}
	println('branch=$branch')
	push.branch = branch
	//push.insert_push()
}

struct Buf {
pub:
	bytes []byte
mut:
	i     int
}

fn (mut b Buf) read(mut buf []byte) ?int {
	if !(b.i < b.bytes.len) {
		return none
	}
	n := copy(buf, b.bytes[b.i..])
	b.i += n
	return n
}


fn make_reader(buf []byte) io.Reader {
	return Buf{buf, 0}
}