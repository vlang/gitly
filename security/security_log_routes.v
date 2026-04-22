module main

import veb

@['/settings/security']
fn (mut app App) security() veb.Result {
	logs := app.get_all_user_security_logs(ctx.user.id)

	return $veb.html()
}
