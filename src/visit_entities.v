module main

struct Visit {
	id         int    [primary; sql: serial]
	repo_id    int
	url        string
	referer    string
	created_at int
}
