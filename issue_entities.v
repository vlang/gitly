module main

struct Issue {
	id int [primary; sql: serial]
mut:
	author_id     int
	repo_id       int
	is_pr         bool
	assigned      []int       [skip]
	labels        []int       [skip]
	nr_comments   int
	title         string
	text          string
	created_at    int
	status        IssueStatus [skip]
	linked_issues []int       [skip]
	author_name   string      [skip]
	repo_author   string      [skip]
	repo_name     string      [skip]
}

enum IssueStatus {
	open = 0
	closed = 1
}

struct Label {
	id    int
	name  string
	color string
}
