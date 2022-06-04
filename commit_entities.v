module main

struct Commit {
mut:
	id         int    [primary; sql: serial]
	author_id  int
	author     string
	hash       string [unique: 'commit']
	created_at int
	repo_id    int    [unique: 'commit']
	branch_id  int
	message    string
}

struct Change {
mut:
	file      string
	additions int
	deletions int
	diff      string
	message   string
}
