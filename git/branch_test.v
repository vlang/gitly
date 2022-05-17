module git

fn test_parse_git_branch_output() {
	branch_name, last_commit_hash := parse_git_branch_output('* main test another_test')

	assert branch_name == 'main'
	assert last_commit_hash == 'test'
}
