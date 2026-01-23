#!/usr/bin/env -S v run

import os
import term

const server      = 'gitly'
const remote_path = '/var/www/gitly'

fn main() {
    println('Step 1: Syncing files...')
    // -a: archive mode (preserves permissions, recursive, etc.)
    // -v: verbose
    // -z: compress
    exec_safe('rsync -avz src translations ${server}:${remote_path}/')

    println('\nStep 2: Remote compilation and restart...')
    remote_cmds := [
        'cd $remote_path',
        '/root/v2/v -d new_veb -d use_openssl .',
        'sudo systemctl restart gitly'
    ].join(' && ')

    println('ssh $server "$remote_cmds"')
    exec_safe('ssh $server "$remote_cmds"')

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

