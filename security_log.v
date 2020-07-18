// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb

enum SecurityLogKind {
	registered
	logged_in
	registered_via_github
	logged_in_via_github
	wrong_password
	wrong_oauth_state
	empty_oauth_code
	empty_oauth_email
}

struct SecurityLog {
	id int
	user_id int
	kind SecurityLogKind
	ip string
	arg1 string
	arg2 string
	created_at int
}

fn (mut app App) security_log(log SecurityLog) {
	log2 := { log | ip: app.vweb.ip() }
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
fn (mut app App) security() vweb.Result {
	logs := app.find_security_logs(app.user.id)
	return $vweb.html()
}
