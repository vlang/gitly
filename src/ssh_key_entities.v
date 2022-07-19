module main

import time

struct SshKey {
	id         int       [primary; sql: serial]
	user_id    int       [unique: 'ssh_key']
	title      string    [unique: 'ssh_key']
	key        string
	created_at time.Time
}
