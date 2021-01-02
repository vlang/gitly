// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import libsodium
import encoding.base64

struct Token {
	id      int
	user_id int
	value   string
	ip      string
}

fn (mut app App) update_user_token(user_id int, token string, ip string) string {
	tok := app.find_user_token(user_id, ip)
	if tok == '' {
		new_token := Token{
			user_id: user_id
			value: token
			ip: ip
		}
		sql app.db {
			insert new_token into Token
		}
		return token
	}
	return tok
}

fn (mut app App) find_user_token(user_id int, ip string) string {
	tok := sql app.db {
		select from Token where user_id == user_id && ip == ip limit 1
	}
	return tok.value
}

fn (mut app App) clear_sessions(user_id int) {
	sql app.db {
		delete from Token where user_id == user_id
	}
}

fn (mut app App) add_token(user_id int, ip string) string {
	u := app.find_user_by_id(user_id) or {
		error('User not found with id $user_id')
		return ''
	}
	mut token := gen_uuid_v4ish()
	token = app.update_user_token(user_id, token, ip)
	//cr_token := string(libsodium.new_secret_box(u.key).encrypt_string(token))
	return base64.encode(token)
}
