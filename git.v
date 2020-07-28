// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import strings

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

// /vlang/info/refs?service=git-upload-pack
fn (mut app App) git_info() vweb.Result {
	app.info('/info/refs')
	app.info(app.vweb.req.method.str())
	// Get service type from the git request.
	// Receive (git push) or upload	(git pull)
	url := app.vweb.req.url
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
		return app.vweb.not_found()
		// }
	} else {
		// public repo push
		if service == .receive {
			user := '' // get_user(c)
			app.info('info/refs user="$user"')
			if user == '' {
				// app.vweb.write_header(http.status_unauthorized)
				return app.vweb.not_found()
			}
		}
	}
	app.vweb.set_content_type('application/x-git-$service-advertisement')
	// hdrNocache(c.Writer)
	app.vweb.add_header('Cache-Control', 'no-cache')
	mut sb := strings.new_builder(100)
	sb.write(packet_write('# service=git-$service\n'))
	sb.write(packet_flush())
	refs := app.repo.git_advertise(service.to_str())
	app.info('refs = ')
	app.info(refs)
	sb.write(refs)
	return app.vweb.ok(sb.str())
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
