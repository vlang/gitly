// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import rand

struct Token {
	id      int    [primary; sql: serial]
	user_id int
	value   string
	ip      string
}

fn (mut app App) has_user_token(user_id int, value string) bool {
	tokens := sql app.db {
		select from Token where user_id == user_id
	}

	for _, token in tokens {
		if token.value == value {
			return true
		}
	}

	return false
}

fn (mut app App) clear_sessions(user_id int) {
	sql app.db {
		delete from Token where user_id == user_id
	}
}

fn (mut app App) add_token(user_id int, ip string) string {
	mut uuid := rand.uuid_v4()

	new_token := Token{
		user_id: user_id
		value: uuid
		ip: ip
	}

	sql app.db {
		insert new_token into Token
	}

	return uuid
}
