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
	id         int    [primary; sql: serial]
	user_id    int
	kind_id    int
	ip         string
	arg1       string
	arg2       string
	created_at int
mut:
	kind SecurityLogKind [skip]
}

fn (mut app App) security_log(log SecurityLog) {
	new_log := SecurityLog{
		...log
		kind_id: int(log.kind)
		ip: app.ip()
	}

	sql app.db {
		insert new_log into SecurityLog
	}
}

fn (app &App) find_security_logs(user_id int) []SecurityLog {
	mut logs := sql app.db {
		select from SecurityLog where user_id == user_id order by id desc
	}

	for i, log in logs {
		logs[i].kind = SecurityLogKind(log.kind_id)
	}

	return logs
}

['/settings/security']
fn (mut app App) security() vweb.Result {
	logs := app.find_security_logs(app.user.id)

	return $vweb.html()
}
