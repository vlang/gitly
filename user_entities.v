module main

struct User {
	id              int    [primary; sql: serial]
	full_name       string
	username        string [unique]
	github_username string
	password        string
	salt            string
	is_github       bool
	is_registered   bool
	is_blocked      bool
	is_admin        bool
	oauth_state     string [skip]
mut:
	// for github oauth XSRF protection
	nr_namechanges       int
	last_namechange_time int
	nr_posts             int
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
	id    int    [primary; sql: serial]
	user  int
	email string [unique]
}

struct Contributor {
	id   int [primary; sql: serial]
	user int [unique: 'contributor']
	repo int [unique: 'contributor']
}
