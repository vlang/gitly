import os
import veb

const http_port = get_port()

fn get_port() int {
	return os.getenv_opt('GITLY_PORT') or { '8080' }.int()
}

enum Lang {
	en
	ru
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

fn build_tr_menu(cur_lang Lang) string {
	println('BUILD TR ${cur_lang}')
	// mut sb := strings.new_builder()
	// sb.write_string('<select>')
	// TODO loop when >2 langs
	s := '<select id=select_lang>' +
		'<option value=en ${if cur_lang == .en { 'selected' } else { '' }}>English</option>' +
		'<option value=ru ${if cur_lang == .ru { 'selected' } else { '' }}>Русский</option></select>'
	/*
	s := match cur_lang {
		.ru { 'English' }
		.en { 'Русский' }
	}
	*/
	return s
}
