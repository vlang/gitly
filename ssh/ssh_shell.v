module main

import os
import config

fn run_ssh_shell(user_id int, conf config.Config) ! {
	mut db := connect_db(conf) or { return error('Failed to connect to database: ${err}') }
	defer {
		db.close() or {}
	}

	mut app := &App{
		db:     db
		config: conf
	}

	user := app.get_user_by_id(user_id) or { return error('User not found') }

	cmd := os.getenv_opt('SSH_ORIGINAL_COMMAND') or {
		println('Hi ${user.username}! You have successfully authenticated via SSH.')
		println('Gitly does not provide shell access. Use git commands only.')
		return error('no SSH_ORIGINAL_COMMAND')
	}

	service, repo_owner, repo_name := parse_ssh_command(cmd) or {
		println('Unrecognized command: ${cmd}')
		return error('invalid SSH command')
	}

	repo := app.find_repo_by_name_and_username(repo_name, repo_owner) or {
		eprintln('Gitly: repository ${repo_owner}/${repo_name} not found')
		exit(1)
	}

	is_write := service == 'receive-pack'

	if is_write {
		if repo.user_id != user.id {
			eprintln('Gitly: access denied - you do not own this repository')
			exit(1)
		}
	} else {
		if !repo.is_public && repo.user_id != user.id {
			eprintln('Gitly: access denied - repository is private')
			exit(1)
		}
	}

	git_path := os.find_abs_path_of_executable('git') or {
		eprintln('Gitly: git not found')
		exit(1)
	}

	real_repo_path := os.real_path(repo.git_dir)

	mut p := os.new_process(git_path)
	p.set_args([service, real_repo_path])
	p.run()
	p.wait()
	exit_code := p.code
	p.close()

	exit(exit_code)
}
