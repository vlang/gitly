module main

enum SecurityLogKind {
	registered // 0
	logged_in
	registered_via_github // 2
	logged_in_via_github
	wrong_password // 4
	wrong_oauth_state
	empty_oauth_code // 6
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
