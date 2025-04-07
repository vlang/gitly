import os
import log
import net.http
import time
import json
import api

const gitly_url = 'http://127.0.0.1:8080'

const default_branch = 'main'

const test_username = 'bob'

const test_github_repo_url = 'https://github.com/vlang/pcre'

const test_github_repo_primary_branch = 'master'

fn main() {
	before()!

	test_index_page()

	ilog('Register the first user `${test_username}`')
	mut register_headers, token := register_user(test_username, '1234zxcv', 'bob@example.com') or {
		exit_with_message(err.str())
	}

	ilog('Check all cookies that must be present')
	assert register_headers.contains(.set_cookie)

	ilog('Ensure the login token is present after registration')
	has_token := token != ''
	assert has_token

	test_user_page(test_username)
	test_login_with_token(test_username, token)
	test_static_served()
	test_oauth_page()

	test_create_repo(token, 'test1', '')
	assert get_repo_commit_count(token, test_username, 'test1', default_branch) == 0
	assert get_repo_issue_count(token, test_username, 'test1') == 0
	assert get_repo_branch_count(token, test_username, 'test1') == 0

	repo_name := 'test2'
	test_create_repo(token, repo_name, test_github_repo_url)
	// wait while repo is cloning
	time.sleep(5 * time.second)
	// get repo
	assert get_repo_commit_count(token, test_username, repo_name, test_github_repo_primary_branch) > 0
	assert get_repo_issue_count(token, test_username, repo_name) == 0
	assert get_repo_branch_count(token, test_username, repo_name) > 0
	test_repo_page(test_username, repo_name)
	test_branch_page(test_username, repo_name, test_github_repo_primary_branch)
	test_repos_page(test_username)
	test_repo_settings_page(test_username, repo_name)
	test_contributors_page(test_username, repo_name)
	// test_issues_page(test_username)
	test_stars_page(test_username)
	test_settings_page(test_username)
	test_commits_page(test_username, repo_name, test_github_repo_primary_branch)
	test_branches_page(test_username, repo_name)
	test_repo_tree(test_username, repo_name, test_github_repo_primary_branch, 'c')
	// this makes sure that the blob (and the tree?) is ready
	test_repo_tree(test_username, repo_name, test_github_repo_primary_branch, 'examples')
	test_blob_page(test_username, repo_name, test_github_repo_primary_branch, 'examples/hello.v')
	// test_refs_page(test_username, repo_name)
	// test_api_branches_count(test_username, repo_name)
	ilog("all tests passed!")

	after()!
}

fn before() ! {
	cd_executable_dir()!

	ilog('Make sure gitly is not running')
	kill_gitly_processes()

	remove_database_if_exists()!
	remove_repos_dir_if_exists()!
	compile_gitly()

	ilog('Start gitly in the background, then wait till gitly starts and is responding to requests')
	spawn run_gitly()

	wait_gitly()
}

fn after() ! {
	remove_database_if_exists()!
	remove_repos_dir_if_exists()!

	ilog('Ensure gitly is stopped')
	kill_gitly_processes()
}

fn run_gitly() {
	gitly_process := os.execute('./gitly.exe &')
	if gitly_process.exit_code != 0 {
		exit_with_message(gitly_process.str())
	}
}

@[noreturn]
fn exit_with_message(message string) {
	println(message)
	exit(1)
}

fn ilog(message string) {
	log.info(message)
}

fn cd_executable_dir() ! {
	executable_dir := os.dir(os.executable())
	// Ensure that we are always running in the gitly folder, no matter what is the starting one:
	os.chdir(os.dir(executable_dir))!

	ilog('Testing first gitly run.')
}

fn kill_gitly_processes() {
	os.execute('pkill -9 gitly.exe')
}

fn remove_database_if_exists() ! {
	ilog('Remove old gitly DB')

	if os.exists('gitly.sqlite') {
		os.rm('gitly.sqlite')!
	}
}

fn remove_repos_dir_if_exists() ! {
	ilog('Remove repos directory')

	if os.exists('repos') {
		os.rmdir_all('repos')!
	}
}

fn compile_gitly() {
	ilog('Compile gitly')
	// TODO: gitly segfaults with mbedtls (some interference with libgit2 initialisation) on Ubuntu 20.04. Investigate why exactly and fix it.
	// Note that using `-d use_openssl` prevents tcc from working, so the compilation will be much slower:
	os.execute('v -d use_libbacktrace -cg -keepc -d use_openssl -o gitly.exe .')
	ilog('Compiled gitly.exe, size: ${os.file_size('gitly.exe')}')
}

fn wait_gitly() {
	for waiting_cycles := 0; waiting_cycles < 50; waiting_cycles++ {
		ilog('\twait: ${waiting_cycles}')
		time.sleep(100 * time.millisecond)
		http.get(prepare_url('')) or { continue }
		break
	}
}

fn prepare_url(path string) string {
	return '${gitly_url}/${path}'
}

fn test_index_page() {
	ilog("Ensure gitly's main page is up")
	index_page_result := http.get(prepare_url('')) or { exit_with_message(err.str()) }
	assert index_page_result.body.contains('<html>')
	assert index_page_result.body.contains('</html>')

	ilog('Ensure there is a welcome and register message')
	assert index_page_result.body.contains("Welcome to Gitly! Looks like you've just set it up, you'll need to register")
	ilog('Ensure there is a Register button')
	assert index_page_result.body.contains("<input type='submit' value='Register'>")

	// Make sure no one's logged in
	assert index_page_result.body.contains("<a href='/login' class='login-button'>Log in</a>")
}

// returns headers and token
fn register_user(username string, password string, email string) !(http.Header, string) {
	response := http.post(prepare_url('register'), 'username=${username}&password=${password}&email=${email}&no_redirect=1') or {
		return err
	}

	mut token := ''
	for val in response.header.values(.set_cookie) {
		token = val.find_between('token=', ';')
	}

	return response.header, token
}

fn test_static_served() {
	ilog('Ensure that static css is served')
	css := http.get(prepare_url('css/gitly.css')) or { exit_with_message(err.str()) }

	assert css.status_code != 404
	assert css.body.contains('body')
	assert css.body.contains('html')
}

fn test_user_page(username string) {
	ilog('Testing the new user /${username} page is up after registration')
	user_page_result := http.get(prepare_url(username)) or { exit_with_message(err.str()) }

	assert user_page_result.body.contains('<h3>${username}</h3>')
}

fn test_repo_page(username string, repo_name string) {
	ilog('Testing the new repo /${username}/${repo_name} page is up')
	repo_page_result := http.get(prepare_url("${username}/${repo_name}")) or { exit_with_message(err.str()) }

	assert repo_page_result.status_code == 200
}

fn test_branch_page(username string, repo_name string, branch_name string) {
	ilog('Testing the new branch /${username}/${repo_name}/tree/${branch_name} page is up')
	branch_page_result := http.get(prepare_url("${username}/${repo_name}/tree/${branch_name}")) or { exit_with_message(err.str()) }

	assert branch_page_result.status_code == 200
}

fn test_repos_page(username string) {
	ilog('Testing the new repos /${username}/repos page is up')
	repos_page_result := http.get(prepare_url("${username}/repos")) or { exit_with_message(err.str()) }

	assert repos_page_result.status_code == 200
}

fn test_contributors_page(username string, repo_name string) {
	ilog('Testing the new contributors /${username}/${repo_name}/contributors page is up')
	contributors_page_result := http.get(prepare_url("${username}/${repo_name}/contributors")) or { exit_with_message(err.str()) }

	assert contributors_page_result.status_code == 200
}

fn test_commits_page(username string, repo_name string, branch_name string) {
	ilog('Testing the new commits /${username}/${repo_name}/${branch_name}/commits/1 page is up')
	// Doesn't work with commits/[no 1]
	commits_page_result := http.get(prepare_url("${username}/${repo_name}/${branch_name}/commits/1")) or { exit_with_message(err.str()) }

	assert commits_page_result.status_code == 200
}

fn test_branches_page(username string, repo_name string) {
	ilog('Testing the new branches /${username}/${repo_name}/branches page is up')
	branches_page_result := http.get(prepare_url("${username}/${repo_name}/branches")) or { exit_with_message(err.str()) }

	assert branches_page_result.status_code == 200
}

fn test_api_branches_count(username string, repo_name string) {
	ilog('Testing if api/v1/${username}/${repo_name}/branches/count works')
	api_branches_count_result := http.get(prepare_url("api/v1/${username}/${repo_name}/branches/count")) or { exit_with_message(err.str()) }
	// api_branches_count_result := http.fetch(
	// 	method:  .get
	// 	url:     prepare_url("api/v1/${username}/${repo_name}/branches/count")
	// ) or { exit_with_message(err.str()) }

	assert api_branches_count_result.status_code == 200

	response_json := json.decode(api.ApiBranchCount, api_branches_count_result.body) or {
		exit_with_message(err.str())
	}
	assert response_json.result > 0
}

fn test_refs_page(username string, repo_name string) {
	ilog('Testing the new refs /${username}/${repo_name}/info/refs page is up')
	refs_page_result := http.get(prepare_url("${username}/${repo_name}/info/refs")) or { exit_with_message(err.str()) }

	assert refs_page_result.status_code == 200
}

fn test_oauth_page() {
	ilog('Testing the new oauth /oauth page is up')
	oauth_page_result := http.get(prepare_url("oauth")) or { exit_with_message(err.str()) }

	assert oauth_page_result.status_code == 200
}

fn test_repo_tree(username string, repo_name string, branch_name string, path string) {
	ilog('Testing the new tree /${username}/${repo_name}/tree/${branch_name}/${path} page is up')
	repo_tree_result := http.get(prepare_url("${username}/${repo_name}/tree/${branch_name}/${path}")) or { exit_with_message(err.str()) }

	assert repo_tree_result.status_code == 200
}
// fn test_issues_page(username string) {
// 	test_endpoint_page("${username}/issues", 'issues')
// }

fn test_stars_page(username string) {
	ilog("Testing the new stars /${username}/stars page is up")
	stars_page_result := http.get(prepare_url("${username}/stars")) or { exit_with_message(err.str()) }

	assert stars_page_result.status_code == 200
}

fn test_settings_page(username string) {
	ilog('Testing the new settings /${username}/settings page is up')
	settings_page_result := http.get(prepare_url("${username}/settings")) or { exit_with_message(err.str()) }

	assert settings_page_result.status_code == 200
}

fn test_blob_page(username string, repo_name string, branch_name string, path string) {
	url := "${username}/${repo_name}/blob/${branch_name}/${path}"
	ilog('Testing the new blob /${url} page is up')
	blob_page_result := http.fetch(
		method:  .get
		url:     prepare_url(url)
	) or { exit_with_message(err.str()) }

	assert blob_page_result.status_code == 200
	assert blob_page_result.body.str().contains('m := r.match_str')
}

fn test_repo_settings_page(username string, repo_name string) {
	test_endpoint_page("${username}/${repo_name}/settings", 'settings')
}

fn test_endpoint_page(endpoint string, pagename string) {
	ilog('Testing the new ${pagename} /${endpoint} page is up')	
	endpoint_result := http.get(prepare_url("${endpoint}")) or { exit_with_message(err.str()) }

	assert endpoint_result.status_code == 200
}

fn test_login_with_token(username string, token string) {
	ilog('Try to login in with `${username}` user token')

	login_result := http.fetch(
		method:  .get
		cookies: {
			'token': token
		}
		url:     prepare_url(username)
	) or { exit_with_message(err.str()) }

	ilog('Ensure that after login, there is a signed in as `${username}` message')

	assert login_result.body.contains('<span>Signed in as</span>')
	assert login_result.body.contains("<a href='/${username}'>${username}</a>")
}

fn test_create_repo(token string, name string, clone_url string) {
	description := 'test description'
	repo_visibility := 'public'

	response := http.fetch(
		method:  .post
		cookies: {
			'token': token
		}
		url:     prepare_url('new')
		data:    'name=${name}&description=${description}&clone_url=${clone_url}&repo_visibility=${repo_visibility}&no_redirect=1'
	) or { exit_with_message(err.str()) }

	assert response.status_code == 200
	assert response.body == 'ok'
}

fn get_repo_commit_count(token string, username string, repo_name string, branch_name string) int {
	response := http.fetch(
		method:  .get
		cookies: {
			'token': token
		}
		url:     prepare_url('api/v1/${username}/${repo_name}/${branch_name}/commits/count')
	) or { exit_with_message(err.str()) }

	response_json := json.decode(api.ApiCommitCount, response.body) or {
		exit_with_message(err.str())
	}
	dump(response_json.result)

	return response_json.result
}

fn get_repo_issue_count(token string, username string, repo_name string) int {
	response := http.fetch(
		method:  .get
		cookies: {
			'token': token
		}
		url:     prepare_url('api/v1/${username}/${repo_name}/issues/count')
	) or { exit_with_message(err.str()) }

	response_json := json.decode(api.ApiIssueCount, response.body) or {
		exit_with_message(err.str())
	}

	return response_json.result
}

fn get_repo_branch_count(token string, username string, repo_name string) int {
	response := http.fetch(
		method:  .get
		cookies: {
			'token': token
		}
		url:     prepare_url('api/v1/${username}/${repo_name}/branches/count')
	) or { exit_with_message(err.str()) }

	response_json := json.decode(api.ApiBranchCount, response.body) or {
		exit_with_message(err.str())
	}

	return response_json.result
}
