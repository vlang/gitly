module main

struct LangStat {
	id          int    [primary; sql: serial]
	repo_id     int    [unique: 'langstat']
	name        string [unique: 'langstat']
	lines_count int
	pct         int // out of 1000
	color       string
}
