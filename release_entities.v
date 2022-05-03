module main

import time

struct Release {
	id      int [primary; sql: serial]
	repo_id int [unique: 'release']
mut:
	tag_id   int       [unique: 'release']
	notes    string
	tag_name string    [skip]
	tag_hash string    [skip]
	user     string    [skip]
	date     time.Time [skip]
}
