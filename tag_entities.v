module main

struct Tag {
	id      int [primary; sql: serial]
	repo_id int [unique: 'tag']
mut:
	name    string [unique: 'tag'] // tag name
	hash    string // hash of latest commit on tag
	user_id int    // id of user that created the tag
	date    int    // time of latest commit on tag
}
