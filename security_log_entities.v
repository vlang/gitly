module main

enum SecurityLogKind {
	registered
	logged_in
	registered_via_github
	logged_in_via_github
	wrong_password
	wrong_oauth_state
	empty_oauth_code
	empty_oauth_email
}

struct SecurityLog {
	id         int    [primary; sql: serial]
	user_id    int
	kind_id    int
	ip         string
	arg1       string
	arg2       string
	created_at int
mut:
	kind SecurityLogKind [skip]
}
