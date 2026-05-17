// Integration tests for every /api/v1/ endpoint exposed by gitly.
//
// The suite spawns its own gitly process on a non-default port using a
// dedicated sqlite database, so it can be executed independently of any
// long-running dev instance (run with `v test api/` or `v test .`).
//
// Endpoints covered:
//   GET  /api/v1/me
//   GET  /api/v1/users/:username
//   GET  /api/v1/users/:username/repos
//   GET  /api/v1/repos/:username/:repo_name
//   GET  /api/v1/repos/:username/:repo_name/issues
//   POST /api/v1/repos/:username/:repo_name/issues
//   GET  /api/v1/repos/:username/:repo_name/issues/:id
//   GET  /api/v1/repos/:username/:repo_name/pulls
//   GET  /api/v1/repos/:username/:repo_name/pulls/:id
//   GET  /api/v1/repos/:username/:repo_name/pulls/:id/comments
//   POST /api/v1/repos/:repo_id/star
//   POST /api/v1/repos/:repo_id/watch
//   GET  /api/v1/repos/:repo_id_str/tree/files
//   GET  /api/v1/:user/:repo_name/branches/count
//   GET  /api/v1/:user/:repo_name/:branch_name/commits/count
//   GET  /api/v1/:username/:repo_name/issues/count
//   POST /api/v1/users/avatar
//   POST /api/v1/ci/status
module api

import os
import log
import net.http
import time
import x.json2 as json

const test_port = 8765
const test_url = 'http://127.0.0.1:${test_port}'
const test_username = 'apitester'
const test_password = '1234zxcv'
const test_email = 'apitester@example.com'
const test_repo = 'apitest'
const test_other_user = 'apitester2'
const test_other_password = '5678qwer'
const test_other_email = 'apitester2@example.com'

const test_binary = 'gitly_apitest.exe'
const test_sqlite_path = 'gitly_apitest.sqlite'

// Test-wide state is passed between testsuite_begin and individual tests via
// environment variables, since `v test` does not allow `__global` declarations
// in module test files.
const env_session = 'GITLY_APITEST_SESSION'
const env_other_session = 'GITLY_APITEST_OTHER_SESSION'
const env_bearer = 'GITLY_APITEST_BEARER'
const env_repo_id = 'GITLY_APITEST_REPO_ID'

fn session_cookie() string {
	return os.getenv(env_session)
}

fn other_session_cookie() string {
	return os.getenv(env_other_session)
}

fn bearer_token() string {
	return os.getenv(env_bearer)
}

fn repo_id() int {
	return os.getenv(env_repo_id).int()
}

// -- testsuite plumbing -------------------------------------------------------

fn testsuite_begin() {
	chdir_to_project_root()
	kill_test_gitly()
	cleanup_test_state()
	ensure_gitly_binary()
	spawn_test_gitly()
	wait_for_test_gitly()

	session := register(test_username, test_password, test_email) or {
		fail('register primary user: ${err}')
	}
	os.setenv(env_session, session, true)

	other := register(test_other_user, test_other_password, test_other_email) or {
		fail('register secondary user: ${err}')
	}
	os.setenv(env_other_session, other, true)

	token := create_api_token(session, test_username) or { fail('create api token: ${err}') }
	os.setenv(env_bearer, token, true)

	create_repo(session, test_repo) or { fail('create repo: ${err}') }

	rid := fetch_test_repo_id() or { fail('fetch repo id: ${err}') }
	os.setenv(env_repo_id, rid.str(), true)
}

fn testsuite_end() {
	kill_test_gitly()
	cleanup_test_state()
}

@[noreturn]
fn fail(msg string) {
	log.error('api endpoints_test: ${msg}')
	kill_test_gitly()
	cleanup_test_state()
	exit(1)
}

fn chdir_to_project_root() {
	project_root := os.real_path(os.join_path(os.dir(@FILE), '..'))
	os.chdir(project_root) or { fail('chdir to project root ${project_root}: ${err}') }
}

fn cleanup_test_state() {
	for ext in ['', '-shm', '-wal'] {
		path := test_sqlite_path + ext
		if os.exists(path) {
			os.rm(path) or {}
		}
	}
	for user in [test_username, test_other_user] {
		repo_path := os.join_path('repos', user)
		if os.exists(repo_path) {
			os.rmdir_all(repo_path) or {}
		}
	}
}

fn ensure_gitly_binary() {
	if os.exists(test_binary) {
		return
	}
	log.info('building ${test_binary} ...')
	res := os.execute('v -d sqlite -d use_libbacktrace -d use_openssl -o ${test_binary} .')
	if res.exit_code != 0 {
		fail('failed to build gitly: ${res.output}')
	}
}

fn spawn_test_gitly() {
	os.setenv('GITLY_PORT', test_port.str(), true)
	os.setenv('GITLY_SQLITE_PATH', test_sqlite_path, true)
	spawn fn () {
		os.execute('./${test_binary}')
	}()
}

fn wait_for_test_gitly() {
	for i := 0; i < 100; i++ {
		time.sleep(100 * time.millisecond)
		http.get(test_url + '/') or { continue }
		return
	}
	fail('gitly did not start listening on ${test_url}')
}

fn kill_test_gitly() {
	os.execute('pkill -9 ${test_binary}')
}

// -- helpers ------------------------------------------------------------------

fn url(path string) string {
	if path.starts_with('/') {
		return '${test_url}${path}'
	}
	return '${test_url}/${path}'
}

fn extract_token_cookie(h http.Header) string {
	for v in h.values(.set_cookie) {
		t := v.find_between('token=', ';')
		if t != '' {
			return t
		}
	}
	return ''
}

fn register(username string, password string, email string) !string {
	body := 'username=${username}&password=${password}&email=${email}&no_redirect=1'
	resp := http.post(url('/register'), body)!
	if resp.status_code != 200 {
		return error('register returned ${resp.status_code}: ${resp.body}')
	}
	tok := extract_token_cookie(resp.header)
	if tok == '' {
		return error('no session token cookie in register response')
	}
	return tok
}

fn create_repo(token string, name string) ! {
	resp := http.fetch(
		method:  .post
		url:     url('/new')
		cookies: {
			'token': token
		}
		data:    'name=${name}&description=api+test&clone_url=&repo_visibility=public&no_redirect=1'
	)!
	if resp.status_code != 200 || resp.body != 'ok' {
		return error('unexpected response ${resp.status_code}: ${resp.body}')
	}
}

fn create_api_token(token string, username string) !string {
	resp := http.fetch(
		method:         .post
		url:            url('/${username}/settings/api-tokens')
		cookies:        {
			'token': token
		}
		data:           'name=api-test'
		allow_redirect: false
	)!
	if resp.status_code != 302 && resp.status_code != 303 {
		return error('expected redirect, got ${resp.status_code}: ${resp.body}')
	}
	location := resp.header.get(.location) or { return error('no Location header') }
	plain := location.all_after('new_token=')
	if plain == '' || plain == location {
		return error('could not parse new_token from ${location}')
	}
	return plain
}

fn fetch_test_repo_id() !int {
	resp := http.get(url('/api/v1/users/${test_username}/repos'))!
	if resp.status_code != 200 {
		return error('listing returned ${resp.status_code}')
	}
	repos := json.decode[[]ApiRepoSummary](resp.body)!
	for r in repos {
		if r.name == test_repo {
			return r.id
		}
	}
	return error('repo not found in listing')
}

struct ApiRepoSummary {
	id        int
	name      string
	user_name string
}

struct ApiUserSummary {
	id        int
	username  string
	full_name string
	avatar    string
}

struct ApiIssueSummary {
	id      int
	number  int
	repo_id int
	title   string
	body    string
	author  string
	status  string
}

struct ApiPullSummary {
	id          int
	repo_id     int
	title       string
	description string
	status      string
}

struct ApiCommentSummary {
	id     int
	author string
	text   string
}

struct ApiBoolResult {
	success bool
	result  bool
}

struct ApiFilesResult {
	success bool
	result  []FileSummary
}

struct FileSummary {
	name      string
	last_msg  string
	last_hash string
	last_time string
	size      string
}

fn bearer_header() http.Header {
	return http.new_header(key: .authorization, value: 'Bearer ${bearer_token()}')
}

// -- tests --------------------------------------------------------------------

fn test_api_v1_me_requires_auth() {
	resp := http.get(url('/api/v1/me')) or { panic(err) }
	assert resp.status_code == 401
}

fn test_api_v1_me_with_bearer() {
	resp := http.fetch(
		method: .get
		url:    url('/api/v1/me')
		header: bearer_header()
	) or { panic(err) }
	assert resp.status_code == 200
	user := json.decode[ApiUserSummary](resp.body) or { panic(err) }
	assert user.username == test_username
}

fn test_api_v1_me_with_session_cookie() {
	resp := http.fetch(
		method:  .get
		url:     url('/api/v1/me')
		cookies: {
			'token': session_cookie()
		}
	) or { panic(err) }
	assert resp.status_code == 200
	user := json.decode[ApiUserSummary](resp.body) or { panic(err) }
	assert user.username == test_username
}

fn test_api_v1_user_lookup() {
	resp := http.get(url('/api/v1/users/${test_username}')) or { panic(err) }
	assert resp.status_code == 200
	user := json.decode[ApiUserSummary](resp.body) or { panic(err) }
	assert user.username == test_username

	missing := http.get(url('/api/v1/users/ghost_user')) or { panic(err) }
	assert missing.status_code == 404
}

fn test_api_v1_user_repos() {
	resp := http.get(url('/api/v1/users/${test_username}/repos')) or { panic(err) }
	assert resp.status_code == 200
	repos := json.decode[[]ApiRepoSummary](resp.body) or { panic(err) }
	assert repos.len >= 1
	mut found := false
	for r in repos {
		if r.name == test_repo {
			found = true
			break
		}
	}
	assert found
}

fn test_api_v1_repo_show() {
	resp := http.get(url('/api/v1/repos/${test_username}/${test_repo}')) or { panic(err) }
	assert resp.status_code == 200
	r := json.decode[ApiRepoSummary](resp.body) or { panic(err) }
	assert r.name == test_repo
	assert r.user_name == test_username

	missing := http.get(url('/api/v1/repos/${test_username}/nope')) or { panic(err) }
	assert missing.status_code == 404
}

fn test_api_v1_repo_issues_list_empty() {
	resp := http.get(url('/api/v1/repos/${test_username}/${test_repo}/issues')) or { panic(err) }
	assert resp.status_code == 200
	issues := json.decode[[]ApiIssueSummary](resp.body) or { panic(err) }
	assert issues.len == 0
}

fn test_api_v1_create_issue_requires_auth() {
	resp := http.post_form(url('/api/v1/repos/${test_username}/${test_repo}/issues'), {
		'title': 'should-fail'
		'body':  'no token'
	}) or { panic(err) }
	assert resp.status_code == 401
}

fn test_api_v1_create_issue_requires_title() {
	resp := http.fetch(
		method: .post
		url:    url('/api/v1/repos/${test_username}/${test_repo}/issues')
		header: http.new_header_from_map({
			.authorization: 'Bearer ${bearer_token()}'
			.content_type:  'application/x-www-form-urlencoded'
		})
		data:   'body=missing-title'
	) or { panic(err) }
	assert resp.status_code == 400
}

fn test_api_v1_create_issue_succeeds() {
	resp := http.fetch(
		method: .post
		url:    url('/api/v1/repos/${test_username}/${test_repo}/issues')
		header: http.new_header_from_map({
			.authorization: 'Bearer ${bearer_token()}'
			.content_type:  'application/x-www-form-urlencoded'
		})
		data:   'title=first-issue&body=hello'
	) or { panic(err) }
	assert resp.status_code == 200
	issue := json.decode[ApiIssueSummary](resp.body) or { panic(err) }
	assert issue.title == 'first-issue'
	assert issue.status == 'open'

	listing := http.get(url('/api/v1/repos/${test_username}/${test_repo}/issues')) or { panic(err) }
	issues := json.decode[[]ApiIssueSummary](listing.body) or { panic(err) }
	assert issues.len >= 1

	single := http.get(url('/api/v1/repos/${test_username}/${test_repo}/issues/${issue.id}')) or {
		panic(err)
	}
	assert single.status_code == 200
	got := json.decode[ApiIssueSummary](single.body) or { panic(err) }
	assert got.id == issue.id
}

fn test_api_v1_repo_issue_not_found() {
	resp := http.get(url('/api/v1/repos/${test_username}/${test_repo}/issues/99999')) or {
		panic(err)
	}
	assert resp.status_code == 404
}

fn test_api_v1_repo_pulls_empty() {
	resp := http.get(url('/api/v1/repos/${test_username}/${test_repo}/pulls')) or { panic(err) }
	assert resp.status_code == 200
	prs := json.decode[[]ApiPullSummary](resp.body) or { panic(err) }
	assert prs.len == 0
}

fn test_api_v1_repo_pull_not_found() {
	resp := http.get(url('/api/v1/repos/${test_username}/${test_repo}/pulls/1')) or { panic(err) }
	assert resp.status_code == 404
}

fn test_api_v1_pull_comments_not_found() {
	resp := http.get(url('/api/v1/repos/${test_username}/${test_repo}/pulls/1/comments')) or {
		panic(err)
	}
	assert resp.status_code == 404
}

fn test_api_v1_issues_count() {
	resp := http.fetch(
		method:  .get
		url:     url('/api/v1/${test_username}/${test_repo}/issues/count')
		cookies: {
			'token': session_cookie()
		}
	) or { panic(err) }
	assert resp.status_code == 200
	decoded := json.decode[ApiIssueCount](resp.body) or { panic(err) }
	assert decoded.success
	assert decoded.result >= 1
}

fn test_api_v1_issues_count_unauthenticated() {
	resp := http.get(url('/api/v1/${test_username}/${test_repo}/issues/count')) or { panic(err) }
	assert resp.body.contains('Not found')
}

fn test_api_v1_branches_count() {
	resp := http.fetch(
		method:  .get
		url:     url('/api/v1/${test_username}/${test_repo}/branches/count')
		cookies: {
			'token': session_cookie()
		}
	) or { panic(err) }
	assert resp.status_code == 200
	decoded := json.decode[ApiBranchCount](resp.body) or { panic(err) }
	assert decoded.success
	assert decoded.result == 0
}

fn test_api_v1_commits_count() {
	resp := http.fetch(
		method:  .get
		url:     url('/api/v1/${test_username}/${test_repo}/main/commits/count')
		cookies: {
			'token': session_cookie()
		}
	) or { panic(err) }
	assert resp.status_code == 200
	decoded := json.decode[ApiCommitCount](resp.body) or { panic(err) }
	assert decoded.success
	assert decoded.result == 0
}

fn test_api_v1_repo_star_toggle() {
	rid := repo_id()
	resp := http.fetch(
		method:  .post
		url:     url('/api/v1/repos/${rid}/star')
		cookies: {
			'token': session_cookie()
		}
	) or { panic(err) }
	assert resp.status_code == 200
	first := json.decode[ApiBoolResult](resp.body) or { panic(err) }
	assert first.success
	assert first.result == true

	resp2 := http.fetch(
		method:  .post
		url:     url('/api/v1/repos/${rid}/star')
		cookies: {
			'token': session_cookie()
		}
	) or { panic(err) }
	second := json.decode[ApiBoolResult](resp2.body) or { panic(err) }
	assert second.result == false
}

fn test_api_v1_repo_watch_toggle() {
	rid := repo_id()
	resp := http.fetch(
		method:  .post
		url:     url('/api/v1/repos/${rid}/watch')
		cookies: {
			'token': session_cookie()
		}
	) or { panic(err) }
	assert resp.status_code == 200
	first := json.decode[ApiBoolResult](resp.body) or { panic(err) }
	assert first.success
}

fn test_api_v1_repo_tree_files_requires_branch() {
	rid := repo_id()
	resp := http.get(url('/api/v1/repos/${rid}/tree/files')) or { panic(err) }
	assert resp.body.contains('branch is required')
}

fn test_api_v1_repo_tree_files_with_branch() {
	rid := repo_id()
	resp := http.get(url('/api/v1/repos/${rid}/tree/files?branch=main')) or { panic(err) }
	assert resp.status_code == 200
	decoded := json.decode[ApiFilesResult](resp.body) or { panic(err) }
	assert decoded.success
}

fn test_api_v1_repo_tree_files_unknown_repo() {
	resp := http.get(url('/api/v1/repos/9999999/tree/files?branch=main')) or { panic(err) }
	assert resp.body.contains('Not found')
}

fn test_api_v1_users_avatar_requires_auth() {
	resp := http.post_multipart_form(url('/api/v1/users/avatar'),
		files: {
			'file': [
				http.FileData{
					filename:     'a.png'
					content_type: 'image/png'
					data:         'x'
				},
			]
		}
	) or { panic(err) }
	assert resp.status_code == 404
}

fn test_api_v1_ci_status_callback() {
	rid := repo_id()
	payload := '{"run_id":"123","repo_id":"${rid}","commit_hash":"deadbeef","branch":"main","status":"running"}'
	resp := http.fetch(
		method: .post
		url:    url('/api/v1/ci/status')
		header: http.new_header(key: .content_type, value: 'application/json')
		data:   payload
	) or { panic(err) }
	assert resp.status_code == 200
	assert resp.body.contains('"success":true') || resp.body.contains('"success": true')
}

fn test_api_v1_ci_status_callback_rejects_bad_json() {
	resp := http.fetch(
		method: .post
		url:    url('/api/v1/ci/status')
		header: http.new_header(key: .content_type, value: 'application/json')
		data:   'not-json'
	) or { panic(err) }
	assert resp.body.contains('Invalid request body')
}

fn test_api_v1_private_repo_visibility_from_other_user() {
	// Sanity check: a second authenticated user can see the public test repo.
	resp := http.fetch(
		method:  .get
		url:     url('/api/v1/repos/${test_username}/${test_repo}')
		cookies: {
			'token': other_session_cookie()
		}
	) or { panic(err) }
	assert resp.status_code == 200
}
