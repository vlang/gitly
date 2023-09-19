// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

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

fn (mut app App) add_security_log(log SecurityLog) ! {
	new_log := SecurityLog{
		...log
		kind_id: int(log.kind)
		ip: app.ip()
	}

	sql app.db {
		insert new_log into SecurityLog
	}!
}

fn (app &App) get_all_user_security_logs(user_id int) []SecurityLog {
	mut logs := sql app.db {
		select from SecurityLog where user_id == user_id order by id desc
	} or { []SecurityLog{} }

	for i, log in logs {
		logs[i].kind = unsafe { SecurityLogKind(log.kind_id) }
	}

	return logs
}
