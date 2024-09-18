module git

import strings
import net.http
import os
import regex

pub fn parse_branch_name_from_receive_upload(upload string) ?string {
	upload_lines := upload.split_into_lines()
	if upload_lines.len == 0 {
		return none
	}
	upload_header := upload_lines[0]
	header_parts := upload_header.fields()
	if header_parts.len < 3 {
		return none
	}
	branch_reference := header_parts[2]
	branch_name_raw := get_branch_name_from_reference(branch_reference)
	branch_name := branch_name_raw.trim_space().trim('\0')
	if branch_name.len == 0 {
		return none
	}
	return branch_name
}

// parse_git_branch_with_last_hash parses output from `git branch -a`
// returns the branch name
pub fn parse_git_branch_output(output string) string {
	output_parts := output.fields()
	asterisk_or_branch_name := output_parts[0]
	if asterisk_or_branch_name == '*' {
		return output_parts[1]
	}
	return output_parts[0]
}

pub fn flush_packet() string {
	return '0000'
}

pub fn write_packet(value string) string {
	packet_length := (value.len + 4).hex()
	return strings.repeat(`0`, 4 - packet_length.len) + packet_length + value
}

pub fn check_git_repo_url(url string) bool {
	repo_url := remove_git_extension_if_exists(url)
	refs_url := '${repo_url}/info/refs?service=git-upload-pack'
	mut headers := http.new_header()
	headers.add_custom('User-Agent', 'git/2.30.0') or {}
	headers.add_custom('Git-Protocol', 'version=2') or {}
	config := http.FetchConfig{
		url:    refs_url
		header: headers
	}
	response := http.fetch(config) or { return false }
	if response.status_code != 200 {
		return false
	}
	return response.body.contains('service=git-upload-pack')
}

pub fn get_git_executable_path() ?string {
	which_result := os.execute('which git')
	which_exit_code := which_result.exit_code
	which_output := which_result.output
	if which_exit_code != 0 {
		return none
	}
	return which_output.trim(' \n')
}

pub fn get_repository_primary_branch(path string) string {
	git_result := os.execute('git -C ${path} symbolic-ref HEAD')
	git_exit_code := git_result.exit_code
	git_output := git_result.output.trim(' \n')
	if git_exit_code != 0 {
		return ''
	}
	return get_branch_name_from_reference(git_output)
}

pub fn remove_git_extension_if_exists(git_repository_name string) string {
	return git_repository_name.trim_string_right('.git')
}

fn get_branch_name_from_reference(value string) string {
	branch_query := r'refs/heads/(.*)'
	mut re := regex.regex_opt(branch_query) or { panic(err) }
	re.match_string(value)
	return re.get_group_by_id(value, 0)
}
