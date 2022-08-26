// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import rand

fn (mut app App) add_token(user_id int, ip string) string {
	mut uuid := rand.uuid_v4()

	token := Token{
		user_id: user_id
		value: uuid
		ip: ip
	}

	sql app.db {
		insert token into Token
	}

	return uuid
}

fn (mut app App) get_token(value string) ?Token {
	token := sql app.db {
		select from Token where value == value limit 1
	}

	if token.id == 0 {
		return none
	}

	return token
}

fn (mut app App) delete_tokens(user_id int) {
	sql app.db {
		delete from Token where user_id == user_id
	}
}
