// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import crypto.sha256
import rand
import encoding.hex

struct ApiToken {
	id int @[primary; sql: serial]
mut:
	user_id      int
	name         string
	token_hash   string
	created_at   int
	last_used_at int
}

fn hash_api_token(plain string) string {
	return sha256.sum(plain.bytes()).hex()
}

fn generate_api_token_plaintext() string {
	mut buf := []u8{len: 24}
	for i in 0 .. buf.len {
		buf[i] = u8(rand.intn(256) or { 0 })
	}
	return 'glt_' + hex.encode(buf)
}

fn (mut app App) add_api_token(user_id int, name string) !(int, string) {
	plain := generate_api_token_plaintext()
	t := ApiToken{
		user_id:    user_id
		name:       name
		token_hash: hash_api_token(plain)
		created_at: int(time.now().unix())
	}
	sql app.db {
		insert t into ApiToken
	}!
	return db_last_insert_id(mut app.db), plain
}

fn (mut app App) list_user_api_tokens(user_id int) []ApiToken {
	return sql app.db {
		select from ApiToken where user_id == user_id order by id desc
	} or { []ApiToken{} }
}

fn (mut app App) delete_api_token(user_id int, id int) ! {
	sql app.db {
		delete from ApiToken where id == id && user_id == user_id
	}!
}

fn (mut app App) user_for_api_token(plain string) ?User {
	if plain == '' {
		return none
	}
	hashed := hash_api_token(plain)
	rows := sql app.db {
		select from ApiToken where token_hash == hashed limit 1
	} or { []ApiToken{} }
	if rows.len == 0 {
		return none
	}
	t := rows.first()
	now := int(time.now().unix())
	id := t.id
	sql app.db {
		update ApiToken set last_used_at = now where id == id
	} or {}
	return app.get_user_by_id(t.user_id)
}
