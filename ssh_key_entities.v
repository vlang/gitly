module main

import time

struct SshKey {
	id         int       [primary; sql: serial]
	user_id    int
	title      string
	key        string
	is_deleted bool
	created_at time.Time
}
