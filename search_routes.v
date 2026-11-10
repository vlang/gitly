module main

import veb
import git

const max_search_query_len = 100

struct CodeSearchResult {
	repo_user string
	repo_name string
	path      string
}

// Preserve international project and user names while preventing callers from
// turning the search box into an unbounded SQL LIKE wildcard query.
fn normalize_search_query(query string) string {
	query_chars := query.runes()
	bounded_query := if query_chars.len > max_search_query_len {
		query_chars[..max_search_query_len]
	} else {
		query_chars
	}
	mut clean := []rune{cap: bounded_query.len}
	for ch in bounded_query {
		if ch < 0x20 || ch == 0x7f || ch in [`%`, `_`] {
			clean << ` `
		} else {
			clean << ch
		}
	}
	return clean.string().fields().join(' ')
}

@['/search']
pub fn (mut app App) search() veb.Result {
	query := (ctx.query['query'] or { '' }).trim_space()
	requested_type := ctx.query['type'] or { 'repos' }
	search_type := if requested_type in ['repos', 'users', 'code'] {
		requested_type
	} else {
		'repos'
	}
	valid_query := normalize_search_query(query)

	repos := if search_type == 'repos' && valid_query != '' {
		app.search_repos(valid_query, if ctx.logged_in { ctx.user.id } else { 0 })
	} else {
		[]Repo{}
	}

	users := if search_type == 'users' && valid_query != '' {
		app.search_users(valid_query)
	} else {
		[]User{}
	}

	mut code_results := []CodeSearchResult{}
	if search_type == 'code' && valid_query != '' {
		code_results = app.search_code(valid_query)
	}

	return $veb.html()
}

fn (mut app App) search_code(query string) []CodeSearchResult {
	mut results := []CodeSearchResult{}
	repos := sql app.db {
		select from Repo where is_public == true limit 20
	} or { []Repo{} }
	for repo in repos {
		res := git.Git.exec_in_dir(repo.git_dir, ['grep', '-l', '-I', query, repo.primary_branch])
		if res.exit_code != 0 {
			continue
		}
		for line in res.output.split_into_lines() {
			path := line.trim_space()
			if path == '' {
				continue
			}
			results << CodeSearchResult{ repo_user: repo.user_name, repo_name: repo.name, path: path }
			if results.len >= 50 {
				break
			}
		}
		if results.len >= 50 {
			break
		}
	}
	return results
}
