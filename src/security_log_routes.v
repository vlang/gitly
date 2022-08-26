module main

import vweb

['/settings/security']
fn (mut app App) security() vweb.Result {
	logs := app.get_all_user_security_logs(app.user.id)

	return $vweb.html()
}
