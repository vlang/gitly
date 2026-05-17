#!/usr/bin/env -S v run

import os
import term

const server = 'gitly'
const remote_path = '/var/www/gitly'
const local_binary = 'gitly_linux'

fn main() {
	if !os.exists(local_binary) {
		eprintln(term.red('${local_binary} not found. Build it first with:'))
		eprintln('  ~/code/v3/v -os linux -d use_openssl -cc clang -o ${local_binary} .')
		exit(1)
	}

	println('Step 1: Syncing binary, static/ and translations/...')
	rsync := 'rsync -avz'
	exec_safe('${rsync} ${local_binary} ${server}:${remote_path}/gitly')
	exec_safe('${rsync} static/ ${server}:${remote_path}/static/')
	exec_safe('${rsync} translations/ ${server}:${remote_path}/translations/')

	println('\nStep 2: Restarting gitly...')
	exec_safe('ssh ${server} "sudo systemctl restart gitly"')

	println(term.green('\nDeployment successful!'))
}

fn exec_safe(cmd string) {
	println('>>> ${cmd}')
	if os.system(cmd) != 0 {
		eprintln(term.red('\n Error executing command.'))
		exit(1)
	}
}
