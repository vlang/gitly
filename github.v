// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import x.json2 as json
import net.http
import time
// import veb.auth as oauth
import veb.oauth

struct GitHubUser {
	username string @[json: 'login']
	name     string
	email    string
	avatar   string @[json: 'avatar_url']
}

struct GitHubIssueAuthor {
	login string
}

struct GitHubPullRequestRef {
	url string
}

struct GitHubLabel {
	name        string
	color       string
	description string
}

struct GitHubRepoInfo {
	description string
}

struct GitHubContributor {
	login      string
	avatar_url string
	type_      string @[json: 'type']
	html_url   string
	id         int
}

struct GitHubIssue {
	number       int
	title        string
	body         string
	state        string
	created_at   string
	user         GitHubIssueAuthor
	pull_request GitHubPullRequestRef
	labels       []GitHubLabel
}

fn parse_github_timestamp(s string) int {
	if s == '' {
		return int(time.now().unix())
	}
	t := time.parse_iso8601(s) or { return int(time.now().unix()) }
	return int(t.unix())
}

fn parse_github_owner_repo(clone_url string) ?(string, string) {
	mut s := clone_url.trim_space()
	for prefix in ['https://', 'http://', 'git@'] {
		if s.starts_with(prefix) {
			s = s[prefix.len..]
			break
		}
	}
	s = s.trim_string_left('github.com')
	s = s.trim_left(':/')
	s = s.trim_string_right('.git')
	s = s.trim('/')
	parts := s.split('/')
	if parts.len < 2 || parts[0] == '' || parts[1] == '' {
		return none
	}
	return parts[0], parts[1]
}

// Returns the local user id for a GitHub login, creating an unregistered
// "shadow" user (no password, no email, just the username and GitHub avatar)
// when one does not yet exist.
fn (mut app App) find_or_create_github_shadow_user(github_login string) !int {
	if u := app.get_user_by_username(github_login) {
		return u.id
	}
	user := User{
		username:        github_login
		github_username: github_login
		is_github:       true
		is_registered:   false
		avatar:          'https://github.com/${github_login}.png'
		created_at:      time.now()
	}
	app.add_user(user)!
	created := app.get_user_by_username(github_login) or {
		return error('shadow user not found after insert: ${github_login}')
	}
	return created.id
}

// fetch_github_repo_description returns the GitHub description for a repo, or
// an empty string if it cannot be retrieved.
fn fetch_github_repo_description(clone_url string) string {
	owner, name := parse_github_owner_repo(clone_url) or {
		eprintln('[github-info] cannot parse github url: ${clone_url}')
		return ''
	}
	url := 'https://api.github.com/repos/${owner}/${name}'
	eprintln('[github-info] GET ${url}')
	mut req := http.new_request(.get, url, '')
	req.add_header(.user_agent, 'gitly')
	req.add_header(.accept, 'application/vnd.github+json')
	resp := req.do() or {
		eprintln('[github-info] request failed: ${err}')
		return ''
	}
	if resp.status_code != 200 {
		eprintln('[github-info] non-200 status ${resp.status_code}: ${resp.body#[..200]}')
		return ''
	}
	info := json.decode[GitHubRepoInfo](resp.body) or {
		eprintln('[github-info] cannot decode response: ${err}')
		return ''
	}
	return info.description
}

fn (mut app App) import_github_contributors(repo_id int, clone_url string) ! {
	eprintln('[github-contrib] starting for repo_id=${repo_id} clone_url=${clone_url}')
	owner, name := parse_github_owner_repo(clone_url) or {
		return error('cannot parse github url: ${clone_url}')
	}
	mut page := 1
	mut total := 0
	for page <= 10 {
		url := 'https://api.github.com/repos/${owner}/${name}/contributors?per_page=100&page=${page}'
		eprintln('[github-contrib] GET ${url}')
		mut req := http.new_request(.get, url, '')
		req.add_header(.user_agent, 'gitly')
		req.add_header(.accept, 'application/vnd.github+json')
		resp := req.do() or { return error('github api request failed: ${err}') }
		if resp.status_code != 200 {
			return error('github api ${resp.status_code}: ${resp.body}')
		}
		contributors := json.decode[[]GitHubContributor](resp.body) or {
			return error('cannot decode github contributors: ${err}')
		}
		if contributors.len == 0 {
			break
		}
		for c in contributors {
			if c.login == '' || c.type_ == 'Bot' {
				continue
			}
			user_id := app.find_or_create_github_shadow_contributor(c.login, c.avatar_url) or {
				eprintln('[github-contrib] cannot resolve @${c.login}: ${err}')
				continue
			}
			app.add_contributor(user_id, repo_id) or {
				eprintln('[github-contrib] cannot link @${c.login}: ${err}')
				continue
			}
			total++
		}
		if contributors.len < 100 {
			break
		}
		page++
	}
	app.update_repo_contributor_count(repo_id) or {
		eprintln('[github-contrib] cannot update contributor count: ${err}')
	}
	eprintln('[github-contrib] done: imported ${total} contributors into repo ${repo_id}')
}

// find_or_create_github_shadow_contributor is like find_or_create_github_shadow_user
// but also stores the GitHub avatar URL when given.
fn (mut app App) find_or_create_github_shadow_contributor(github_login string, avatar_url string) !int {
	if u := app.get_user_by_username(github_login) {
		return u.id
	}
	avatar := if avatar_url != '' { avatar_url } else { 'https://github.com/${github_login}.png' }
	user := User{
		username:        github_login
		github_username: github_login
		is_github:       true
		is_registered:   false
		avatar:          avatar
		created_at:      time.now()
	}
	app.add_user(user)!
	created := app.get_user_by_username(github_login) or {
		return error('shadow user not found after insert: ${github_login}')
	}
	return created.id
}

fn (mut app App) import_github_issues(repo_id int, clone_url string, owner_user_id int) ! {
	eprintln('[github-import] starting for repo_id=${repo_id} clone_url=${clone_url} owner_user_id=${owner_user_id}')
	owner, name := parse_github_owner_repo(clone_url) or {
		eprintln('[github-import] ERROR: cannot parse github url: ${clone_url}')
		return error('cannot parse github url: ${clone_url}')
	}
	eprintln('[github-import] parsed owner=${owner} name=${name}')
	mut page := 1
	mut total := 0
	for page <= 100 {
		url := 'https://api.github.com/repos/${owner}/${name}/issues?state=open&per_page=100&page=${page}'
		eprintln('[github-import] GET ${url}')
		mut req := http.new_request(.get, url, '')
		req.add_header(.user_agent, 'gitly')
		req.add_header(.accept, 'application/vnd.github+json')
		resp := req.do() or {
			eprintln('[github-import] ERROR: request failed: ${err}')
			return error('github api request failed: ${err}')
		}
		eprintln('[github-import] page=${page} status=${resp.status_code} body_len=${resp.body.len}')
		if resp.status_code != 200 {
			eprintln('[github-import] ERROR body: ${resp.body}')
			return error('github api ${resp.status_code}: ${resp.body}')
		}
		issues := json.decode[[]GitHubIssue](resp.body) or {
			eprintln('[github-import] ERROR: cannot decode response: ${err}')
			eprintln('[github-import] response body was: ${resp.body#[..1000]}')
			return error('cannot decode github issues: ${err}')
		}
		eprintln('[github-import] decoded ${issues.len} issues on page ${page}')
		if issues.len == 0 {
			break
		}
		for gi in issues {
			// GitHub returns PRs in the issues endpoint; skip them.
			if gi.pull_request.url != '' {
				eprintln('[github-import] skipping PR #${gi.number}')
				continue
			}
			mut author_id := owner_user_id
			if gi.user.login != '' {
				author_id = app.find_or_create_github_shadow_user(gi.user.login) or {
					eprintln('[github-import] cannot resolve author @${gi.user.login}: ${err}')
					owner_user_id
				}
			}
			created_at := parse_github_timestamp(gi.created_at)
			issue_id := app.add_imported_issue_returning_id(repo_id, author_id, gi.title, gi.body,
				created_at) or {
				eprintln('[github-import] ERROR inserting issue #${gi.number}: ${err}')
				continue
			}
			app.increment_repo_issues(repo_id) or {
				eprintln('[github-import] cannot bump issue count: ${err}')
			}
			for gl in gi.labels {
				if gl.name == '' {
					continue
				}
				color := if gl.color == '' { 'cccccc' } else { gl.color }
				label_id := app.find_or_create_label(repo_id, gl.name, color) or {
					eprintln('[github-import] cannot create label ${gl.name}: ${err}')
					continue
				}
				if label_id == 0 {
					continue
				}
				app.add_issue_label(issue_id, label_id) or {
					eprintln('[github-import] cannot link label ${gl.name} to issue #${gi.number}: ${err}')
				}
			}
			total++
		}
		if issues.len < 100 {
			break
		}
		page++
	}
	eprintln('[github-import] done: imported ${total} issues into repo ${repo_id}')
}

@['/oauth']
pub fn (mut app App) handle_oauth() veb.Result {
	code := ctx.query['code']
	state := ctx.query['state']

	if code == '' {
		app.add_security_log(user_id: ctx.user.id, kind: .empty_oauth_code) or {
			app.info(err.str())
		}
		app.info('Code is empty')

		return ctx.redirect_to_index()
	}

	csrf := ctx.get_cookie('csrf') or { return ctx.redirect_to_index() }
	if csrf != state || csrf == '' {
		app.add_security_log(
			user_id: ctx.user.id
			kind:    .wrong_oauth_state
			arg1:    'csrf=${csrf}'
			arg2:    'state=${state}'
		) or { app.info(err.str()) }

		return ctx.redirect_to_index()
	}

	oauth_request := oauth.Request{
		client_id:     app.settings.oauth_client_id
		client_secret: app.settings.oauth_client_secret
		code:          code
		state:         csrf
	}

	js := json.encode(oauth_request)
	access_response := http.post_json('https://github.com/login/oauth/access_token', js) or {
		app.info(err.msg())

		return ctx.redirect_to_index()
	}

	mut token := access_response.body.find_between('access_token=', '&')
	mut request := http.new_request(.get, 'https://api.github.com/user', '')
	request.add_header(.authorization, 'token ${token}')

	user_response := request.do() or {
		app.info(err.msg())

		return ctx.redirect_to_index()
	}

	if user_response.status_code != 200 {
		app.info(user_response.status_code.str())
		app.info(user_response.body)
		return ctx.text('Received ${user_response.status_code} error while attempting to contact GitHub')
	}

	github_user := json.decode[GitHubUser](user_response.body) or { return ctx.redirect_to_index() }

	if github_user.email.trim_space().len == 0 {
		app.add_security_log(
			user_id: ctx.user.id
			kind:    .empty_oauth_email
			arg1:    user_response.body
		) or { app.info(err.str()) }
		app.info('Email is empty')
	}

	mut user := app.get_user_by_github_username(github_user.username) or { User{} }

	if !user.is_github {
		// Register a new user via github
		app.add_security_log(
			user_id: user.id
			kind:    .registered_via_github
			arg1:    user_response.body
		) or { app.info(err.str()) }

		app.register_user(github_user.username, '', '', [github_user.email], true, false) or {
			app.info(err.msg())
		}

		user = app.get_user_by_github_username(github_user.username) or {
			return ctx.redirect_to_index()
		}

		app.update_user_avatar(user.id, github_user.avatar) or { app.info(err.msg()) }
	}

	app.auth_user(mut ctx, user, ctx.ip()) or { app.info(err.msg()) }
	app.add_security_log(user_id: user.id, kind: .logged_in_via_github, arg1: user_response.body) or {
		app.info(err.str())
	}

	return ctx.redirect_to_index()
}
