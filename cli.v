// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os

pub fn (mut app App) command_fetcher() {
	for {
		line := os.get_line()
		if line.starts_with('!') {
			args := line[1..].split(' ')
			if args.len > 0 {
				match args[0] {
					'updaterepo' {
						app.update_repo()
					}
					'adduser' {
						if args.len > 4 {
							app.add_user(args[1], args[2], args[3..], false, false)
							println('Added user ${args[1]}')
						} else {
							error('Not enough arguments (3 required but only $args.len given)')
						}
					}
					else {
						println('Commands:')
						println('	!updaterepo')
						println('	!adduser <username> <password> <email1> <email2>...')
					}
				}
			} else {
				error('Unkown syntax. Use !<command>')
			}
		} else {
			error('Unkown syntax. Use !<command>')
		}
	}
}
