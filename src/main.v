import os
import veb

const http_port = get_port()

fn get_port() int {
	return os.getenv_opt('GITLY_PORT') or { '8080' }.int()
}

fn main() {
	if os.args.contains('ci_run') {
		return
	}
	mut app := new_app()!

	app.use(handler: app.before_request)
	// vweb.run_at(new_app()!, http_port)

	veb.run_at[App, Context](mut app, port: http_port, family: .ip, timeout_in_seconds: 5) or {
		panic(err)
	}
}
