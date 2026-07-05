module main

fn test_sha256_ssh_fingerprint() {
	input := []u8{len: 32}
	fp := sha256_ssh_fingerprint(input)
	assert fp.starts_with('SHA256:')
	assert fp.len > 10
	assert !fp.contains('=')
}

fn test_sha256_ssh_fingerprint_deterministic() {
	input := [u8(0x01), 0x02, 0x03, 0x04]
	fp1 := sha256_ssh_fingerprint(input)
	fp2 := sha256_ssh_fingerprint(input)
	assert fp1 == fp2
}

fn test_parse_ssh_public_key_ed25519() {
	raw := 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK0wNqGrGGqEfg1lMC8kYFMBpWfJ7iW6JzJ0YJ9m0vBb test@example.com'
	key_type, fingerprint := parse_ssh_public_key(raw) or {
		assert false, 'failed to parse valid ed25519 key: ${err}'
		return
	}
	assert key_type == 'ssh-ed25519'
	assert fingerprint.starts_with('SHA256:')
	assert fingerprint.len > 10
}

fn test_parse_ssh_public_key_rsa() {
	raw := 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC4x7fBZf6ZcYO2sVF8G0f5h0Q0PfG5gN5vz0z5fK3p6WJkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZkY2RjZg== test@example.com'
	key_type, fingerprint := parse_ssh_public_key(raw) or {
		assert false, 'failed to parse valid rsa key: ${err}'
		return
	}
	assert key_type == 'ssh-rsa'
	assert fingerprint.starts_with('SHA256:')
}

fn test_parse_ssh_public_key_invalid_type() {
	raw := 'unknown-key-type AAAA test@example.com'
	parse_ssh_public_key(raw) or {
		assert err.msg().contains('unsupported')
		return
	}
	assert false, 'expected error for unsupported key type'
}

fn test_parse_ssh_public_key_missing_fields() {
	raw := 'ssh-rsa'
	parse_ssh_public_key(raw) or {
		assert err.msg().contains('missing')
		return
	}
	assert false, 'expected error for missing fields'
}

fn test_parse_ssh_public_key_empty() {
	parse_ssh_public_key('') or {
		assert err.msg().contains('missing')
		return
	}
	assert false, 'expected error for empty key'
}

fn test_parse_ssh_public_key_ecdsa() {
	raw := 'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBK0wNqGrGGqEfg1lMC8kYFMBpWfJ7iW6JzJ0YJ9m0vBb8zVfG5aKX4gJc7n9Vh6w0p2RKqFd2Lq1Yb5e3m8LkQ== test@example.com'
	key_type, fingerprint := parse_ssh_public_key(raw) or {
		assert false, 'failed to parse valid ecdsa key: ${err}'
		return
	}
	assert key_type == 'ecdsa-sha2-nistp256'
	assert fingerprint.starts_with('SHA256:')
}

fn test_parse_ssh_command_upload() {
	service, username, repo_name := parse_ssh_command("git-upload-pack 'user/myrepo.git'") or {
		assert false, 'failed to parse valid upload command'
		return
	}
	assert service == 'upload-pack'
	assert username == 'user'
	assert repo_name == 'myrepo'
}

fn test_parse_ssh_command_receive() {
	service, username, repo_name := parse_ssh_command("git-receive-pack 'user/myrepo.git'") or {
		assert false, 'failed to parse valid receive command'
		return
	}
	assert service == 'receive-pack'
	assert username == 'user'
	assert repo_name == 'myrepo'
}

fn test_parse_ssh_command_without_git_suffix() {
	service, username, repo_name := parse_ssh_command("git-upload-pack 'user/myrepo'") or {
		assert false, 'failed to parse command without .git suffix'
		return
	}
	assert service == 'upload-pack'
	assert username == 'user'
	assert repo_name == 'myrepo'
}

fn test_parse_ssh_command_invalid_service() {
	parse_ssh_command("git-receive-pack2 'user/myrepo.git'") or { return }
	assert false, 'expected error for invalid service'
}

fn test_parse_ssh_command_no_slash() {
	parse_ssh_command("git-upload-pack 'myrepo.git'") or { return }
	assert false, 'expected error for missing slash'
}

fn test_parse_ssh_command_empty() {
	parse_ssh_command('') or { return }
	assert false, 'expected error for empty command'
}

fn test_fingerprint_different_keys() {
	raw1 := 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK0wNqGrGGqEfg1lMC8kYFMBpWfJ7iW6JzJ0YJ9m0vBb test@example.com'
	raw2 := 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8zVfG5aKX4gJc7n9Vh6w0p2RKqFd2Lq1Yb5e3m8LkQ other@example.com'
	_, fp1 := parse_ssh_public_key(raw1) or {
		assert false
		return
	}
	_, fp2 := parse_ssh_public_key(raw2) or {
		assert false
		return
	}
	assert fp1 != fp2
}

fn test_hex_char_to_byte() {
	assert hex_char_to_byte(`0`)! == 0
	assert hex_char_to_byte(`9`)! == 9
	assert hex_char_to_byte(`a`)! == 10
	assert hex_char_to_byte(`f`)! == 15
	hex_char_to_byte(`g`) or { return }
	assert false, 'expected error for invalid hex char'
}

fn test_ssh_public_key_with_extra_whitespace() {
	raw := '  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK0wNqGrGGqEfg1lMC8kYFMBpWfJ7iW6JzJ0YJ9m0vBb   test@example.com  '
	key_type, fingerprint := parse_ssh_public_key(raw) or {
		assert false, 'failed to parse key with whitespace: ${err}'
		return
	}
	assert key_type == 'ssh-ed25519'
	assert fingerprint.starts_with('SHA256:')
}

fn test_ssh_public_key_dsa() {
	raw := 'ssh-dss AAAAB3NzaC1kc3MAAACBAK0wNqGrGGqEfg1lMC8kYFMBpWfJ7iW6JzJ0YJ9m0vBb8zVfG5aKX4gJc7n9Vh6w0p2RKqFd2Lq1Yb5e3m8LkQAAAAFQC4x7fBZf6ZcYO2sVF8G0f5h0Q0PAAAA== test@example.com'
	key_type, fingerprint := parse_ssh_public_key(raw) or {
		assert false, 'failed to parse valid dsa key: ${err}'
		return
	}
	assert key_type == 'ssh-dss'
	assert fingerprint.starts_with('SHA256:')
}
