module git

import os
import time

pub const clone_size_limit_exit_code = 125
pub const clone_size_limit_marker = '[gitly:clone-size-limit]'

pub struct Git {}

pub fn Git.exec(args []string) os.Result {
	mut git_args := ['git']
	git_args << args
	return os.exec(git_args)
}

pub fn Git.exec_in_dir(dir string, args []string) os.Result {
	mut git_args := ['-C', dir]
	git_args << args
	return Git.exec(git_args)
}

pub fn Git.exec_in_dir_command(dir string, command string) os.Result {
	args := split_command(command) or {
		return os.Result{
			exit_code: -1
			output:    'invalid git command: ${err}'
		}
	}
	return Git.exec_in_dir(dir, args)
}

// NOTE: there is deliberately no `exec_shell` wrapper here. Handing a
// concatenated command string to `/bin/sh -c` is how command injection gets
// introduced, and it is never needed: every caller below builds an argument
// vector and passes it to `os.exec`, so arguments are never re-parsed by a
// shell. Add an argument-array helper rather than a string one.

// Git.exec_in_dir_with_env runs `git -C <dir> <args...>` without going through a
// shell, with `extra_env` added on top of the inherited environment. Use this
// instead of building a shell string when any argument or environment value is
// user-controlled (file paths, branch names, commit messages, author names),
// since arguments are passed directly to git and never re-parsed by /bin/sh.
pub fn Git.exec_in_dir_with_env(dir string, args []string, extra_env map[string]string) os.Result {
	mut full_args := ['-C', dir]
	full_args << args
	mut p := os.new_process('git')
	p.set_args(full_args)
	mut merged := os.environ()
	for k, v in extra_env {
		merged[k] = v
	}
	p.set_environment(merged)
	// Git commands (especially hooks) can write enough data to stderr to fill
	// its pipe. Reading stdout to EOF before reading stderr then deadlocks: the
	// child is blocked on stderr and cannot close stdout. A merged pipe keeps the
	// same output contract as os.exec and can always be drained safely.
	p.set_redirect_stdio_merged()
	p.run()
	output := p.stdout_slurp()
	p.wait()
	code := p.code
	p.close()
	return os.Result{
		exit_code: code
		output:    output
	}
}

pub fn Git.clone(url string, path string) os.Result {
	return os.exec(['git', '-c', 'http.followRedirects=false', 'clone', '--bare', url, path])
}

// Git.clone_with_progress runs `git clone --bare --progress` and streams
// every byte of git's progress output (which goes to stderr) into
// `progress_path` while the clone is running, so a separate process can
// poll the file and show live progress to the user.
pub fn Git.clone_with_progress(url string, path string, progress_path string) os.Result {
	return Git.clone_with_progress_limit(url, path, progress_path, 0)
}

pub fn Git.clone_with_progress_limit(url string, path string, progress_path string, max_bytes u64) os.Result {
	os.rm(progress_path) or {}
	clone_args := ['-c', 'http.followRedirects=false', 'clone', '--bare', '--progress', url, path]
	mut log := os.open_append(progress_path) or {
		eprintln('clone_with_progress: cannot open progress file "${progress_path}": ${err}')
		// os.exec captures stdout and stderr through one pipe, so this fallback
		// cannot deadlock even when Git writes a large diagnostic.
		mut git_args := ['git']
		git_args << clone_args
		return os.exec(git_args)
	}
	mut p := os.new_process('git')
	p.set_args(clone_args)
	mut environment := os.environ()
	// Progress parsing relies on Git's stable English labels.
	environment['LC_ALL'] = 'C'
	p.set_environment(environment)
	p.set_redirect_stdio()
	p.run()
	mut collected := ''
	mut stdout_output := ''
	mut stopped_for_size := false
	for p.is_alive() {
		chunk := p.stderr_read()
		if chunk.len > 0 {
			log.write_string(chunk) or {}
			log.flush()
			collected += chunk
			if max_bytes > 0 && !stopped_for_size
				&& clone_progress_received_bytes(collected) >= max_bytes {
				stopped_for_size = true
				marker := '\n${clone_size_limit_marker}\n'
				log.write_string(marker) or {}
				log.flush()
				collected += marker
				p.signal_term()
				time.sleep(500 * time.millisecond)
				if p.is_alive() {
					p.signal_kill()
				}
			}
		}
		// Drain and retain stdout so the pipe cannot block the child and callers
		// do not lose diagnostics that Git happens to emit there.
		stdout_output += p.stdout_read()
		time.sleep(100 * time.millisecond)
	}
	stdout_output += p.stdout_slurp()
	final := p.stderr_slurp()
	if final.len > 0 {
		log.write_string(final) or {}
		log.flush()
		collected += final
	}
	// A short-lived clone may exit before the polling loop observes its last
	// progress update. Apply the limit to the final drain as well.
	if max_bytes > 0 && !stopped_for_size && clone_progress_received_bytes(collected) >= max_bytes {
		stopped_for_size = true
		marker := '\n${clone_size_limit_marker}\n'
		log.write_string(marker) or {}
		log.flush()
		collected += marker
	}
	log.close()
	p.wait()
	exit_code := if stopped_for_size { clone_size_limit_exit_code } else { p.code }
	p.close()
	return os.Result{
		exit_code: exit_code
		output:    collected + stdout_output
	}
}

pub fn clone_progress_received_bytes(progress string) u64 {
	mut max_bytes := u64(0)
	for line in progress.replace('\r', '\n').split('\n') {
		if !line.contains('Receiving objects:') {
			continue
		}
		bytes := parse_clone_progress_size(line) or { continue }
		if bytes > max_bytes {
			max_bytes = bytes
		}
	}
	return max_bytes
}

fn parse_clone_progress_size(line string) ?u64 {
	comma := line.index('),') or { return none }
	mut size_part := line[comma + 2..].trim_space()
	separator := size_part.index('|') or { size_part.len }
	size_part = size_part[..separator].trim_space()
	parts := size_part.fields()
	if parts.len != 2 || !valid_clone_progress_number(parts[0]) {
		return none
	}
	value := parts[0].f64()
	multiplier := match parts[1] {
		'B', 'byte', 'bytes' { 1.0 }
		'KiB' { 1024.0 }
		'MiB' { 1024.0 * 1024.0 }
		'GiB' { 1024.0 * 1024.0 * 1024.0 }
		else { return none }
	}

	return u64(value * multiplier)
}

fn valid_clone_progress_number(value string) bool {
	mut digits := 0
	mut decimal_points := 0
	for ch in value {
		if ch >= `0` && ch <= `9` {
			digits++
		} else if ch == `.` {
			decimal_points++
			if decimal_points > 1 {
				return false
			}
		} else {
			return false
		}
	}
	return digits > 0
}

pub fn Git.fetch_ref(repo_dir string, remote string, refspec string) os.Result {
	return Git.exec_in_dir(repo_dir, ['fetch', remote, refspec])
}

pub fn Git.show_file_blob(repo_dir string, branch string, file_path string) !string {
	result := Git.exec_in_dir(repo_dir, ['--no-pager', 'show', '${branch}:${file_path}'])
	if result.exit_code != 0 {
		return error(result.output)
	}
	return result.output
}

fn split_command(command string) ![]string {
	mut args := []string{}
	mut current := []u8{}
	mut quote := u8(0)
	mut has_arg := false
	mut i := 0
	for i < command.len {
		ch := command[i]
		if quote == 0 && ch.is_space() {
			if has_arg {
				args << current.bytestr()
				current.clear()
				has_arg = false
			}
			i++
			continue
		}
		if ch == `"` || ch == `'` {
			if quote == 0 {
				quote = ch
				has_arg = true
				i++
				continue
			}
			if quote == ch {
				quote = 0
				i++
				continue
			}
		}
		if ch == `\\` && quote != `'` {
			if i + 1 < command.len {
				next := command[i + 1]
				escapable := if quote == `"` {
					next == `"` || next == `\\`
				} else {
					next.is_space() || next == `'` || next == `"` || next == `\\`
				}
				if escapable {
					current << next
					has_arg = true
					i += 2
					continue
				}
			}
			current << ch
			has_arg = true
			i++
			continue
		}
		current << ch
		has_arg = true
		i++
	}
	if quote != 0 {
		return error('unterminated quote')
	}
	if has_arg {
		args << current.bytestr()
	}
	return args
}
