module main

fn (mut app App) add_ssh_key(user_id int, title string, key string) {
	ssh_key := SshKey{
		user_id: user_id
		title: title
		key: key
		is_deleted: false
	}

	sql app.db {
		insert ssh_key into SshKey
	}
}

fn (mut app App) find_ssh_keys(user_id int) []SshKey {
	return sql app.db {
		select from SshKey where user_id == user_id && is_deleted == false
	}
}

fn (mut app App) remove_ssh_key(id int) {
	sql app.db {
		delete from SshKey where id == id
	}
}
