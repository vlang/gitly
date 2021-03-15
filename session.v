// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time
import vweb
import crypto.sha256
import encoding.base64

// user specific data
struct Session {
mut:
	show_menu     bool
	page_gen_time string
	path          string // current path being viewed
	logged_in     bool
	repo          Repo
	user          User
	is_tree       bool
	html_path     vweb.RawHtml
	form_error    string
}

fn (mut app App) get_session(mut c vweb.Context) &Session {
	if id := c.get_cookie('sess_id') {
		if id in app.user_sessions {
			return app.user_sessions[id]
		}
	}
	// TODO: cache eviction
	sess_id := generate_session_id()
	cookie := vweb.Cookie{
		name: 'sess_id',
		value: sess_id,
		secure: true,
		http_only: true,
		expires: time.now().add_days(1),
	}
	c.set_cookie(cookie)
	app.user_sessions[sess_id] = &Session{}
	return app.user_sessions[sess_id]
}

fn generate_session_id() string {
	mut f := os.open_file('/dev/urandom', 'r') or {
		panic('could not open /dev/urandom')
	}
	defer { f.close() }
	b := f.read_bytes(256)
	return base64.encode(sha256.sum(b))
}
