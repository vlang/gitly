import os
import net.http
import time

fn main() {
	println('testing first gitly run...')

	os.execute('pkill -9 gitly')
	if os.exists('gitly.sqlite') {
		os.rm('gitly.sqlite') ?
	}

	os.execute('v .')
	go run_gitly()

	time.sleep(1 * time.second)

	if index_page_result := http.get('http://127.0.0.1:8080') {
		assert index_page_result.text.contains('<html>')
		assert index_page_result.text.contains('</html>')
		assert index_page_result.text.contains("Welcome to Gitly! Looks like you've just set it up, you'll need to register")
		assert index_page_result.text.contains("<input type='submit' value='Register'>")

		// Make sure no one's logged in
		assert index_page_result.text.contains("<a href='/login' class='login-button'>Log in</a>")
	} else {
		println(err)

		exit(1)
	}

	// Register the first user (admin)
	mut register_result := http.post('http://127.0.0.1:8080/register_post', 'username=bob&password=1234zxcv&email=bob@example.com&no_redirect=1') or {
		println(err)

		exit(1)
	}

	// Check all cookies that must be present
	assert register_result.header.contains(.set_cookie)

	mut has_token := false
	mut token := ''

	for val in register_result.header.values(.set_cookie) {
		token = val.find_between('token=', ';')

		has_token = token != ''
	}

	assert has_token

	user_page_result := http.get('http://127.0.0.1:8080/bob') or {
		println(err)
		exit(1)
	}

	assert user_page_result.text.contains('<h3> bob </h3>')

	// Try loggin in with user token
	login_result := http.fetch(
		method: .get
		cookies: {
			'token': token
		}
		url: 'http://127.0.0.1:8080/bob'
	) or {
		println(err)
		exit(1)
	}

	assert login_result.text.contains('<span>Signed in as</span>')
	assert login_result.text.contains("<a href='/bob'>bob</a>")

	time.sleep(3 * time.second)
}

fn run_gitly() {
	gitly_process := os.execute('./gitly')

	if gitly_process.exit_code != 0 {
		println(gitly_process)

		exit(1)
	}
}
