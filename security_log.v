// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import vweb
import json
import net.http

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
}

fn (mut app App) security_log(log SecurityLog) {
	log2 := { log | ip: app.vweb.ip() }
	sql app.db {
		insert log2 into SecurityLog
	}
}
