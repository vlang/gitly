module git

fn test_parse_git_branch_output() {
	branch_name := parse_git_branch_output('* main')

	assert branch_name == 'main'
}
