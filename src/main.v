import os
import vweb

fn main() {
	if os.args.contains('ci_run') {
		return
	}
	vweb.run(new_app()!, http_port)
}
