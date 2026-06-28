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
	return Git.exec_in_dir(dir, split_command(command))
}

pub fn Git.exec_shell(command string) os.Result {
	return os.exec(['/bin/sh', '-c', command])
}

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
	p.set_redirect_stdio()
	p.run()
	output := p.stdout_slurp() + p.stderr_slurp()
	p.wait()
	code := p.code
	p.close()
	return os.Result{
		exit_code: code
		output:    output
	}
}

pub fn Git.clone(url string, path string) os.Result {
	println('new clone url="${url}" path="${path}"')
	return os.exec(['git', 'clone', '--bare', url, path])
}

// Git.clone_with_progress runs `git clone --bare --progress` and streams
// every byte of git's progress output (which goes to stderr) into
// `progress_path` while the clone is running, so a separate process can
// poll the file and show live progress to the user.
pub fn Git.clone_with_progress(url string, path string, progress_path string) os.Result {
	return Git.clone_with_progress_limit(url, path, progress_path, 0)
}

pub fn Git.clone_with_progress_limit(url string, path string, progress_path string, max_bytes u64) os.Result {
	println('new clone (progress) url="${url}" path="${path}" progress="${progress_path}"')
	os.rm(progress_path) or {}
	mut p := os.new_process('git')
	p.set_args(['clone', '--bare', '--progress', url, path])
	p.set_redirect_stdio()
	p.run()
	mut log := os.open_append(progress_path) or {
		eprintln('clone_with_progress: cannot open progress file "${progress_path}": ${err}')
		// fall back to non-streaming behaviour
		p.wait()
		out := p.stdout_slurp() + p.stderr_slurp()
		code := p.code
		p.close()
		return os.Result{
			exit_code: code
			output:    out
		}
	}
	mut collected := ''
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
		// drain stdout so the pipe buffer never blocks the child
		_ := p.stdout_read()
		time.sleep(100 * time.millisecond)
	}
	final := p.stderr_slurp()
	if final.len > 0 {
		log.write_string(final) or {}
		log.flush()
		collected += final
	}
	log.close()
	p.wait()
	exit_code := if stopped_for_size { clone_size_limit_exit_code } else { p.code }
	p.close()
	return os.Result{
		exit_code: exit_code
		output:    collected
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
	pipe := size_part.index('|') or { size_part.len }
	size_part = size_part[..pipe].trim_space()
	parts := size_part.fields()
	if parts.len < 2 {
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

fn split_command(command string) []string {
	mut args := []string{}
	mut current := []u8{}
	mut quote := u8(0)
	mut escaped := false

	for ch in command.bytes() {
		if escaped {
			current << ch
			escaped = false
			continue
		}
		if ch == `\\` {
			escaped = true
			continue
		}
		if quote != 0 {
			if ch == quote {
				quote = 0
			} else {
				current << ch
			}
			continue
		}
		if ch == `"` || ch == `'` {
			quote = ch
			continue
		}
		if ch.is_space() {
			if current.len > 0 {
				args << current.bytestr()
				current.clear()
			}
			continue
		}
		current << ch
	}
	if current.len > 0 {
		args << current.bytestr()
	}
	return args
}
