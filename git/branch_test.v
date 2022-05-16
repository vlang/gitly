module git

fn test_parse_git_branch_with_last_hash() {
	branch_name, last_commit_hash := parse_git_branch_with_last_hash('* main test another_test')

	assert branch_name == 'main'
	assert last_commit_hash == 'test'
}
