module git

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
