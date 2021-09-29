import os
import net.http
import time

fn main() {
	println('testing first gitly run...')
	// os.execute('pkill -9 gitly')
	if os.exists('gitly.sqlite') {
		// os.rm('gitly.sqlite') ?
	}
	os.execute('v .')
	// go run_gitly()
	time.sleep(1 * time.second)
	println('done')
	if x := http.get('http://127.0.0.1:8080') {
		// println('OKKK')
		// println(x.text)
		assert x.text.contains('<html>')
		assert x.text.contains('</html>')
		assert x.text.contains('<html>')
		assert x.text.contains("Welcome to Gitly! Looks like you've just set it up, you'll need to register")
		assert x.text.contains("<input type='submit' value='Register'>")
		// assert x.text.contains('Gitly is an upcoming open-source development platform that is going to have')
		// Make sure no one's logged in
		assert x.text.contains("<a href='/login' class='login-button'>Sign in</a>")
	} else {
		println('failed to http.get')
		println(err)
		exit(1)
	}
	// Register the first user (admin)
	mut x := http.post('http://127.0.0.1:8080/register_post', 'username=bob&password=1234zxcv&email=bob@example.com&no_redirect=1') or {
		println('failed to register admin')
		println(err)
		exit(1)
	}
	// check all cookies that must be present
	assert x.header.contains(.set_cookie)
	mut has_id := false
	mut has_token := false
	for val in x.header.values(.set_cookie) {
		if val.contains('id=1') {
			has_id = true
		}
		if val.contains('token=') && val.contains('-') {
			has_token = true
		}
	}
	assert has_id
	assert has_token
	println(x.header.values(.set_cookie))
	// assert x.header
	// println(x.text)
	// println(x.header)
	// println(x)
	// exit(0)
	x = http.get('http://127.0.0.1:8080/bob') or {
		println('failed to go to user page')
		println(err)
		exit(1)
	}
	//
	assert x.text.contains('<h3> bob </h3>')

	time.sleep(20 * time.second)
}

fn run_gitly() {
	res := os.execute('./gitly')
	if res.exit_code != 0 {
		println(res)
		exit(1)
	}
}
