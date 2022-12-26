module main

import vweb

fn (app App) add_lang_stat(lang_stat LangStat) {
	sql app.db {
		insert lang_stat into LangStat
	}
}

pub fn (l &LangStat) pct_html() vweb.RawHtml {
	x := f64(l.pct) / 10.0
	sloc := if l.lines_count < 1000 {
		l.lines_count.str()
	} else {
		(l.lines_count / 1000).str() + 'k'
	}

	return '<span>${x}%</span> <span class=lang-stat-loc>${sloc} loc</span>'
}

pub fn (app App) find_repo_lang_stats(repo_id int) []LangStat {
	return sql app.db {
		select from LangStat where repo_id == repo_id order by pct desc
	}
}

fn (app App) remove_repo_lang_stats(repo_id int) {
	sql app.db {
		delete from LangStat where repo_id == repo_id
	}
}
