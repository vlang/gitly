module main

import os
import time
import crypto.sha256
import encoding.base64

struct SshKey {
	id          int    @[primary; sql: serial]
	user_id     int    @[unique: 'ssh_key']
	title       string @[unique: 'ssh_key']
	key         string
	key_type    string
	fingerprint string
	created_at  time.Time
}

fn (mut app App) add_ssh_key(user_id int, title string, key string) ! {
	ssh_keys := sql app.db {
		select from SshKey where user_id == user_id && title == title limit 1
	} or { [] }

	if ssh_keys.len != 0 {
		return error('SSH Key already exists')
	}

	key_type, fingerprint := parse_ssh_public_key(key) or { return error('Invalid SSH key') }

	existing := sql app.db {
		select from SshKey where fingerprint == fingerprint limit 1
	} or { [] }
	if existing.len != 0 {
		return error('SSH key already exists on another account')
	}

	new_ssh_key := SshKey{
		user_id:     user_id
		title:       title
		key:         key
		key_type:    key_type
		fingerprint: fingerprint
		created_at:  time.now()
	}

	sql app.db {
		insert new_ssh_key into SshKey
	}!
}

fn (mut app App) find_ssh_keys(user_id int) []SshKey {
	return sql app.db {
		select from SshKey where user_id == user_id
	} or { [] }
}

fn (mut app App) find_all_ssh_keys() []SshKey {
	return sql app.db {
		select from SshKey
	} or { [] }
}

fn (mut app App) find_user_by_key_fingerprint(fingerprint string) ?User {
	keys := sql app.db {
		select from SshKey where fingerprint == fingerprint limit 1
	} or { return none }
	if keys.len == 0 {
		return none
	}
	return app.get_user_by_id(keys[0].user_id)
}

fn (mut app App) remove_ssh_key(user_id int, id int) ! {
	sql app.db {
		delete from SshKey where id == id && user_id == user_id
	}!
}

fn parse_ssh_public_key(raw string) !(string, string) {
	trimmed := raw.trim_space()
	parts := trimmed.fields()
	if parts.len < 2 {
		return error('missing key type and base64-encoded key')
	}
	key_type := parts[0]
	if key_type !in ['ssh-rsa', 'ssh-dss', 'ssh-ed25519', 'ecdsa-sha2-nistp256',
		'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521'] {
		return error('unsupported key type: ${key_type}')
	}
	b64_data := parts[1]
	decoded := base64.decode(b64_data)
	fingerprint := sha256_ssh_fingerprint(decoded)
	return key_type, fingerprint
}

fn sha256_ssh_fingerprint(raw_key []u8) string {
	hex_str := sha256.hexhash(raw_key.bytestr())
	mut raw_bytes := []u8{len: 32}
	for i := 0; i < 32; i++ {
		high := hex_char_to_byte(hex_str[i * 2]) or { return '' }
		low := hex_char_to_byte(hex_str[i * 2 + 1]) or { return '' }
		raw_bytes[i] = (high << 4) | low
	}
	return 'SHA256:' + base64.encode(raw_bytes).trim_right('=')
}

fn hex_char_to_byte(c u8) !u8 {
	return match c {
		`0`...`9` { c - `0` }
		`a`...`f` { c - `a` + 10 }
		else { error('invalid hex character') }
	}
}

fn (mut app App) sync_ssh_authorized_keys() ! {
	if !app.config.ssh.enabled {
		return
	}

	keys := app.find_all_ssh_keys()
	mut entries := []string{}

	for key in keys {
		app.get_user_by_id(key.user_id) or { continue }
		shell_path := app.config.ssh.binary_path
		entry := 'command="${shell_path} -ssh-shell ${key.user_id}",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${key.key_type} ${key.key} ${key.title}'
		entries << entry
	}

	os.write_file(app.config.ssh.authorized_keys_path, entries.join('\n') + '\n')!
}

fn parse_ssh_command(cmd string) ?(string, string, string) {
	parts := cmd.fields()
	if parts.len < 2 {
		return none
	}
	service := parts[0]
	repo_arg := parts[1].trim("'").trim_string_right('.git')
	if service !in ['git-upload-pack', 'git-receive-pack'] {
		return none
	}
	slash_pos := repo_arg.index('/') or { return none }
	username := repo_arg[..slash_pos]
	repo_name := repo_arg[slash_pos + 1..]
	if username == '' || repo_name == '' {
		return none
	}
	service_type := if service == 'git-receive-pack' { 'receive-pack' } else { 'upload-pack' }
	return service_type, username, repo_name
}
