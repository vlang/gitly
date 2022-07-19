module main

import time

struct Activity {
mut:
	id         int       [primary; sql: serial]
	user_id    int
	name       string
	created_at time.Time
}
