module main

struct Star {
	id      int [primary; sql: serial]
	user_id int [unique: 'repo_star']
	repo_id int [unique: 'repo_star']
}
