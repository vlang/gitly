module main

import time

struct User {
	id              int       [primary; sql: serial]
	full_name       string
	username        string    [unique]
	github_username string
	password        string
	salt            string
	created_at      time.Time
	is_github       bool
	is_registered   bool
	is_blocked      bool
	is_admin        bool
	oauth_state     string    [skip]
mut:
	// for github oauth XSRF protection
	namechanges_count    int
	last_namechange_time int
	posts_count          int
	last_post_time       int
	avatar               string
	b_avatar             bool    [skip]
	emails               []Email [skip]
	login_attempts       int
}

struct SshKey {
	id         int    [primary; sql: serial]
	user       int
	title      string
	sshkey     string
	is_deleted bool
}

struct Email {
	id      int    [primary; sql: serial]
	user_id int
	email   string [unique]
}

struct Contributor {
	id      int [primary; sql: serial]
	user_id int [unique: 'contributor']
	repo_id int [unique: 'contributor']
}
