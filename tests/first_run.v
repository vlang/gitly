import os
import net.http
import time

[noreturn]
fn exit_with_message(message string) {
	println(message)
	exit(1)
}

fn ilog(message string) {
	println('$time.now().format_ss_milli() | $message')
}

fn main() {
	ilog('Testing first gitly run.')

	ilog('Make sure gitly is not running')
	os.execute('pkill -9 gitly')

	ilog('Remove old gitly DB')
	if os.exists('gitly.sqlite') {
		os.rm('gitly.sqlite')?
	}

	ilog('Compile gitly')
	os.execute('v .')

	ilog('Start gitly in the background, then wait till gitly starts and is responding to requests')
	go run_gitly()
	for waiting_cycles := 0; waiting_cycles < 50; waiting_cycles++ {
		ilog('    wait: $waiting_cycles')
		time.sleep(100 * time.millisecond)
		http.get('http://127.0.0.1:8080') or { continue }
		break
	}

	ilog("Ensure gitly's main page is up")
	index_page_result := http.get('http://127.0.0.1:8080') or { exit_with_message(err.str()) }
	assert index_page_result.text.contains('<html>')
	assert index_page_result.text.contains('</html>')

	ilog('Ensure there is a welcome and register message')
	assert index_page_result.text.contains("Welcome to Gitly! Looks like you've just set it up, you'll need to register")
	ilog('Ensure there is a Register button')
	assert index_page_result.text.contains("<input type='submit' value='Register'>")

	// Make sure no one's logged in
	assert index_page_result.text.contains("<a href='/login' class='login-button'>Log in</a>")

	ilog('Register the first user `bob`')
	mut register_result := http.post('http://127.0.0.1:8080/register', 'username=bob&password=1234zxcv&email=bob@example.com&no_redirect=1') or {
		exit_with_message(err.str())
	}
	ilog('Check all cookies that must be present')
	assert register_result.header.contains(.set_cookie)

	ilog('Ensure the login token is present after registration')
	mut has_token := false
	mut token := ''
	for val in register_result.header.values(.set_cookie) {
		token = val.find_between('token=', ';')
		has_token = token != ''
	}
	assert has_token

	ilog('Testing the new user /bob page is up after registration')
	user_page_result := http.get('http://127.0.0.1:8080/bob') or { exit_with_message(err.str()) }
	assert user_page_result.text.contains('<h3>bob</h3>')

	ilog('Try to login in with `bob` user token')
	login_result := http.fetch(
		method: .get
		cookies: {
			'token': token
		}
		url: 'http://127.0.0.1:8080/bob'
	) or { exit_with_message(err.str()) }

	ilog('Ensure that after login, there is a signed in as `bob` message')
	assert login_result.text.contains('<span>Signed in as</span>')
	assert login_result.text.contains("<a href='/bob'>bob</a>")

	ilog('Ensure gitly is stopped')
	os.execute('pkill -9 gitly')
}

fn run_gitly() {
	gitly_process := os.execute('./gitly &')
	if gitly_process.exit_code != 0 {
		exit_with_message(gitly_process.str())
	}
}
