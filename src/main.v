import os
import vweb

const http_port = os.getenv_opt('GITLY_PORT') or { '8080' }.int()

fn main() {
	if os.args.contains('ci_run') {
		return
	}
	vweb.run(new_app()!, http_port)
}
