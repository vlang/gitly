module main

import crypto.sha256

// Regression tests for the input validation that guards git command
// construction in create_file_in_bare_repo (see repo/file_routes.v). These
// inputs used to be interpolated into shell strings; they are now passed to
// git as plain arguments, but we still reject values git could misread as
// flags/refs or that contain control characters.

fn test_is_valid_repo_file_path_accepts_normal_paths() {
	assert is_valid_repo_file_path('README.md')
	assert is_valid_repo_file_path('src/main.v')
	assert is_valid_repo_file_path('dir/file,with,commas.txt')
	assert is_valid_repo_file_path('a/b/c/d.e')
}

fn test_is_valid_repo_file_path_rejects_dangerous_paths() {
	assert !is_valid_repo_file_path('')
	assert !is_valid_repo_file_path('/etc/passwd') // absolute
	assert !is_valid_repo_file_path('-rf') // looks like a flag
	assert !is_valid_repo_file_path('../../etc/passwd') // traversal
	assert !is_valid_repo_file_path('a/../../b') // traversal
	assert !is_valid_repo_file_path('file\nname') // newline
	assert !is_valid_repo_file_path('file\x00name') // NUL
	assert !is_valid_repo_file_path('a\tb') // tab / control char
}

fn test_is_safe_ref_accepts_normal_branches() {
	assert is_safe_ref('master')
	assert is_safe_ref('feature/new-thing')
	assert is_safe_ref('release-1.2.3')
}

fn test_is_safe_ref_rejects_injection_attempts() {
	assert !is_safe_ref('')
	assert !is_safe_ref('--upload-pack=touch /tmp/pwned') // leading dash + space
	assert !is_safe_ref('master;rm -rf /') // shell metacharacters
	assert !is_safe_ref('master$(whoami)')
	assert !is_safe_ref('master`id`')
	assert !is_safe_ref('a..b') // ref traversal
	assert !is_safe_ref('branch with spaces')
}

// Webhook SSRF guard: the IP classifiers must reject internal destinations and
// allow public ones. (is_safe_webhook_url itself does DNS and isn't unit-tested.)

fn test_is_blocked_ipv4_blocks_internal_ranges() {
	assert is_blocked_ipv4('127.0.0.1') // loopback
	assert is_blocked_ipv4('10.1.2.3') // private
	assert is_blocked_ipv4('172.16.5.5') // private
	assert is_blocked_ipv4('172.31.255.255') // private (edge)
	assert is_blocked_ipv4('192.168.0.1') // private
	assert is_blocked_ipv4('169.254.169.254') // link-local / cloud metadata
	assert is_blocked_ipv4('0.0.0.0') // unspecified
	assert is_blocked_ipv4('100.64.0.1') // CGNAT
	assert is_blocked_ipv4('224.0.0.1') // multicast
	assert is_blocked_ipv4('garbage') // unparseable -> fail closed
}

fn test_is_blocked_ipv4_allows_public() {
	assert !is_blocked_ipv4('8.8.8.8')
	assert !is_blocked_ipv4('1.1.1.1')
	assert !is_blocked_ipv4('172.32.0.1') // just outside 172.16/12
	assert !is_blocked_ipv4('172.15.0.1') // just outside 172.16/12
	assert !is_blocked_ipv4('93.184.216.34')
}

fn test_is_blocked_ipv6() {
	assert is_blocked_ipv6('::1') // loopback
	assert is_blocked_ipv6('::') // unspecified
	assert is_blocked_ipv6('fe80::1') // link-local
	assert is_blocked_ipv6('fc00::1') // unique-local
	assert is_blocked_ipv6('fd12:3456::1') // unique-local
	assert is_blocked_ipv6('::ffff:127.0.0.1') // IPv4-mapped loopback
	assert !is_blocked_ipv6('2606:4700:4700::1111') // public
	assert !is_blocked_ipv6('::ffff:8.8.8.8') // IPv4-mapped public
}

// Password hashing: new hashes must be bcrypt, and legacy salted-SHA-256 hashes
// must still verify (so existing users aren't locked out before re-login).

fn test_new_passwords_are_bcrypt() {
	h := hash_password_with_salt('s3cret-pw', 'ignored-salt')
	assert h.starts_with('$2') // bcrypt hash
	assert !password_hash_is_legacy(h)
	assert compare_password_with_hash('s3cret-pw', 'ignored-salt', h)
	assert !compare_password_with_hash('wrong-pw', 'ignored-salt', h)
}

fn test_legacy_sha256_hashes_still_verify() {
	salt := 'abc123'
	// Legacy scheme was sha256('${password}${salt}').
	legacy := sha256.sum('hunter2${salt}'.bytes()).hex()
	assert password_hash_is_legacy(legacy)
	assert compare_password_with_hash('hunter2', salt, legacy)
	assert !compare_password_with_hash('nope', salt, legacy)
}
