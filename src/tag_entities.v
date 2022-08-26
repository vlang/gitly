module main

struct Tag {
	id      int [primary; sql: serial]
	repo_id int [unique: 'tag']
mut:
	name       string [unique: 'tag']
	hash       string
	message    string
	user_id    int
	created_at int
}
