import os
import veb
import config

enum Lang {
	en
	ru
}

fn get_port(conf config.Config) int {
	// Priority: -p flag > GITLY_PORT env > config.json port > 8080
	for i, arg in os.args {
		if (arg == '-p' || arg == '--port') && i + 1 < os.args.len {
			return os.args[i + 1].int()
		}
	}
	env_port := os.getenv_opt('GITLY_PORT') or { '' }
	if env_port != '' {
		return env_port.int()
	}
	if conf.port > 0 {
		return conf.port
	}
	return 8080
}

fn main() {
	if os.args.contains('ci_run') {
		return
	}
	mut app := new_app()!

	app.use(handler: app.before_request)

	app.port = get_port(app.config)

	veb.run_at[App, Context](mut app,
		port:               app.port
		family:             .ip
		timeout_in_seconds: 5
	) or { panic(err) }
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
