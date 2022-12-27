module main

struct Watch {
	id      int [primary; sql: serial]
	user_id int [unique: 'repo_watch']
	repo_id int [unique: 'repo_watch']
}
