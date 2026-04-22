module main

import veb
import regex

@['/search']
pub fn (mut app App) search() veb.Result {
	query := ctx.query['query']
	search_type := if 'type' in ctx.query { ctx.query['type'] } else { 'repos' }
	sanitize_query := r'[a-zA-z0-9]+'
	mut re := regex.regex_opt(sanitize_query) or { panic(err) }

	valid_query := re.find_all_str(query).join(' ')

	repos := if search_type == 'repos' {
		app.search_public_repos(valid_query)
	} else {
		[]Repo{}
	}

	users := if search_type == 'users' {
		app.search_users(valid_query)
	} else {
		[]User{}
	}

	return $veb.html()
}
