// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb

enum SecurityLogKind {
	registered // 0
	logged_in
	registered_via_github // 2
	logged_in_via_github
	wrong_password // 4
	wrong_oauth_state
	empty_oauth_code // 6
	empty_oauth_email
}

struct SecurityLog {
	id         int
	user_id    int
	kind       SecurityLogKind
	ip         string
	arg1       string
	arg2       string
	created_at int
}

fn (mut app App) security_log(c &vweb.Context, log SecurityLog) {
	log2 := SecurityLog{
		...log
		ip: c.ip()
	}
	sql app.db {
		insert log2 into SecurityLog
	}
}

fn (app &App) find_security_logs(user_id int) []SecurityLog {
	return sql app.db {
		select from SecurityLog where user_id == user_id order by id desc
	}
}

['/settings/security']
fn (mut app App) security(mut c vweb.Context) vweb.Result {
	mut sess := app.get_session(mut c)
	logs := app.find_security_logs(sess.user.id)
	return $vweb.html()
}
