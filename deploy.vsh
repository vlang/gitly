#!/usr/bin/env -S v run

import os
import term

const server = 'gitly'
const remote_path = '/var/www/gitly'
const local_binary = 'gitly_linux'

// Shared SSH connection so the key passphrase is only asked once.
const control_path = os.join_path(os.temp_dir(), 'gitly_deploy_cm.sock')
const ssh_opts = '-o ControlMaster=auto -o ControlPath=${control_path} -o ControlPersist=5m'

fn main() {
	if !os.exists(local_binary) {
		eprintln(term.red('${local_binary} not found. Build it first with:'))
		eprintln('  ~/code/v3/v -os linux -d use_openssl -cc clang -gc none -prealloc -cflags "-O2" -o ${local_binary} .')
		exit(1)
	}

	// Open a single master connection up front (prompts for the passphrase once).
	// Every rsync/ssh below reuses it via the control socket.
	println('Opening shared SSH connection...')
	exec_safe('ssh ${ssh_opts} -fN ${server}')
	defer {
		os.system('ssh ${ssh_opts} -O exit ${server} 2>/dev/null')
	}

	println('Step 1: Syncing binary, static/ and translations/...')
	rsync := 'rsync -avz -e "ssh ${ssh_opts}"'
	exec_safe('${rsync} ${local_binary} ${server}:${remote_path}/gitly')
	exec_safe('${rsync} static/ ${server}:${remote_path}/static/')
	exec_safe('${rsync} translations/ ${server}:${remote_path}/translations/')

	println('\nStep 2: Restarting gitly...')
	exec_safe('ssh ${ssh_opts} ${server} "sudo systemctl restart gitly"')

	println(term.green('\nDeployment successful!'))
}

fn exec_safe(cmd string) {
	println('>>> ${cmd}')
	if os.system(cmd) != 0 {
		eprintln(term.red('\n Error executing command.'))
		exit(1)
	}
}
