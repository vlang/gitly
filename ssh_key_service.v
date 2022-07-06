module main

import time

fn (mut app App) add_ssh_key(user_id int, title string, key string) ? {
	ssh_key := sql app.db {
		select from SshKey where user_id == user_id && title == title limit 1
	}

	if ssh_key.id != 0 {
		return error('SSH Key already exists')
	}

	new_ssh_key := SshKey{
		user_id: user_id
		title: title
		key: key
		created_at: time.now()
	}

	sql app.db {
		insert new_ssh_key into SshKey
	}
}

fn (mut app App) find_ssh_keys(user_id int) []SshKey {
	return sql app.db {
		select from SshKey where user_id == user_id
	}
}

fn (mut app App) remove_ssh_key(user_id int, id int) {
	sql app.db {
		delete from SshKey where id == id && user_id == user_id
	}
}
