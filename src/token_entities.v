module main

struct Token {
	id      int    [primary; sql: serial]
	user_id int
	value   string
	ip      string
}
