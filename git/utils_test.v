module git

fn test_get_branch_name_from_reference() {
	assert get_branch_name_from_reference('refs/heads/master') == 'master'
	assert get_branch_name_from_reference('refs/heads/main') == 'main'
	assert get_branch_name_from_reference('refs/heads/fix-110') == 'fix-110'
}
