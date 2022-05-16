module git

// parse_git_branch_with_last_hash parses output from `git branch -av`
// returns the branch name with hash of the last commit
pub fn parse_git_branch_with_last_hash(output string) (string, string) {
	output_parts := output.split(' ')

	asterisk_or_branch_name := output_parts[0]

	if asterisk_or_branch_name == '*' {
		return output_parts[1], output_parts[2]
	}

	return output_parts[0], output_parts[1]
}
