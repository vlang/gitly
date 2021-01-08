module main

import vweb

const (
	test_lang_stats = [
		LangStat{
			name: 'V'
			pct: 989
			nr_lines: 96657
			color: '#5d87bd'
		},
		LangStat{
			name: 'JavaScript'
			nr_lines: 1131
			color: '#f1e05a'
			pct: 11
		},
	]
)

struct LangStat {
	id       int
	repo_id  int
	name     string
	nr_lines int
	pct      int // out of 1000
	color    string
}

pub fn (l &LangStat) pct_html() vweb.RawHtml {
	x := f64(l.pct) / 10.0
	sloc := if l.nr_lines < 1000 { l.nr_lines.str() } else { (l.nr_lines / 1000).str() + 'k' }
	return '<span>$x%</span> <span class=lang-stat-loc>$sloc loc</span>'
}

pub fn (mut app App) find_repo_lang_stats(repo_id int) []LangStat {
	lang_stats := sql app.db {
		select from LangStat where repo_id == repo_id order by pct desc
	}
	return lang_stats
}
