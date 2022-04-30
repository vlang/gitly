module main

import crypto.sha256

pub fn (mut app App) set_user_block_status(user_id int, status bool) {
	sql app.db {
		update User set is_blocked = status where id == user_id
	}
}

pub fn (mut app App) set_user_admin_status(user_id int, status bool) {
	sql app.db {
		update User set is_admin = status where id == user_id
	}
}

fn hash_password_with_salt(password string, salt string) string {
	set_rand_crypto_safe_seed()

	salted_password := '$password$salt'

	return sha256.sum(salted_password.bytes()).hex().str()
}

fn compare_password_with_hash(password string, salt string, hashed string) bool {
	return hash_password_with_salt(password, salt) == hashed
}
