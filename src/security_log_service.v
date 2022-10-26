// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

fn (mut app App) add_security_log(log SecurityLog) {
	new_log := SecurityLog{
		...log
		kind_id: int(log.kind)
		ip: app.ip()
	}

	sql app.db {
		insert new_log into SecurityLog
	}
}

fn (app &App) get_all_user_security_logs(user_id int) []SecurityLog {
	mut logs := sql app.db {
		select from SecurityLog where user_id == user_id order by id desc
	}

	for i, log in logs {
		logs[i].kind = unsafe { SecurityLogKind(log.kind_id) }
	}

	return logs
}
