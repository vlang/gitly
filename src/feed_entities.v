module main

import time

// now only for commits
struct FeedItem {
	id          int
	author_name string
	created_at  time.Time
	repo_name   string
	repo_owner  string
	branch_name string
	message     string
}
