// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import rand
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
	mut sess := app.user_sessions[c.get_cookie('sess_id') or { '' }]
	defer {
		sess.logged_in = app.logged_in(mut c)
		if sess.logged_in {
				sess.user = app.get_user_from_cookies(mut c) or {
				sess.logged_in = false
				User{}
			}
		}
	}

	if sess != 0 {
		return sess
	}

	// TODO: cache eviction
	// TODO: is rand.string strong enough for session IDs?
	sess_id := rand.string(32)
	cookie := vweb.Cookie{
		name: 'sess_id',
		value: sess_id,
		secure: true,
		http_only: true,
		// expires: time.now().add_days(1),
	}
	c.set_cookie(cookie)

	sess = &Session{}
	app.user_sessions[sess_id] = sess
	return sess
}
