#!/usr/bin/env -S v run

import os
import term

const server = 'gitly'
const remote_path = '/var/www/gitly'

const rsync_excludes = [
	'.git/',
	'.github/',
	'.claude/',
	'.vscode/',
	'.idea/',
	'.DS_Store',
	'gitly_ci/',
	'website/',
	'tests/',
	'archives/',
	'avatars/',
	'repos/',
	'logs/',
	'config.json',
	'static/css/gitly.css',
	'static/css/gitly.css.map',
	'*.sqlite',
	'*.sqlite-*',
	'*.bkup',
	'*.dSYM/',
	'*.dylib',
	'*.exe',
	'/gitly',
	'/build',
	'/deploy',
	'/setup_db',
	'/kekw',
]

fn main() {
	println('Step 1: Syncing files...')
	// -a: archive mode (preserves permissions, recursive, etc.)
	// -v: verbose
	// -z: compress
	mut rsync := 'rsync -avz'
	for pattern in rsync_excludes {
		rsync += ' --exclude=${os.quoted_path(pattern)}'
	}
	exec_safe('${rsync} ./ ${server}:${remote_path}/')

	println('\nStep 2: Remote compilation and restart...')
	remote_cmds := [
		'cd ${remote_path}',
		'/root/v2/v -keepc -d use_openssl .',
		'sudo systemctl restart gitly',
	].join(' && ')

	println('ssh ${server} "${remote_cmds}"')
	exec_safe('ssh ${server} "${remote_cmds}"')

	println(term.green('\nDeployment successful!'))
}

fn exec_safe(cmd string) {
	// os.system streams output directly to stdout/stderr,
	// which is better for seeing rsync progress and compiler errors.
	if os.system(cmd) != 0 {
		eprintln(term.red('\n Error executing command.'))
		exit(1)
	}
}
