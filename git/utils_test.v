module git

fn test_get_branch_name_from_reference() {
	assert get_branch_name_from_reference('refs/remotes/origin/master') == 'master'
	assert get_branch_name_from_reference('refs/remotes/origin/main') == 'main'
	assert get_branch_name_from_reference('refs/remotes/origin/fix-110') == 'fix-110'
}
