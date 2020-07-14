// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

struct Token {
	id int
	user_id int
	value string
}

fn (mut app App) update_user_token(user_id int, token string) {
	tok := app.find_user_token(user_id)
	if tok == '' {
		new_token := Token{user_id: user_id, value: token }
		sql app.db {
			insert new_token into Token
		}
	}
	else {
		sql app.db {
			// TODO fix a bug in ORM
			//update Token set value = token where user_id == user_id
			delete from Token where user_id == user_id
		}
		new_token := Token{user_id: user_id, value: token }
		sql app.db {
			insert new_token into Token
		}
	}
}

fn (mut app App) find_user_token(user_id int) string {
	tok := sql app.db {
		select from Token where user_id == user_id limit 1
	}
	return tok.value
}

fn (mut app App) add_token(user_id int) string {
	token := gen_uuid_v4ish()
	app.update_user_token(user_id, token)
	return token
}



