module main

import vweb
import regex

@['/search']
pub fn (mut app App) search() vweb.Result {
	query := app.query['query']
	search_type := if 'type' in app.query { app.query['type'] } else { 'repos' }
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

	return $vweb.html()
}
