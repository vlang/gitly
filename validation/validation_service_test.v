module validation

fn test_is_username_valid() {
	assert is_username_valid('gitly')
	assert is_username_valid('Gitly')
	assert is_username_valid('gitly1')
	assert is_username_valid('git.ly')
	assert is_username_valid('git3.ly')
	assert is_username_valid('git3ly_')

	assert is_username_valid('_gitly') == false
	assert is_username_valid('git-ly') == false
	assert is_username_valid('1gitly') == false
	assert is_username_valid('') == false
	assert is_username_valid(' ') == false
	assert is_username_valid(' 33') == false
	assert is_username_valid(' gitly') == false
	assert is_username_valid('#gitly') == false
}

fn test_is_repository_name_valid() {
	assert is_repository_name_valid('gitly')
	assert is_repository_name_valid('Gitly')
	assert is_repository_name_valid('gitly1')
	assert is_repository_name_valid('git.ly')
	assert is_repository_name_valid('git3.ly')
	assert is_repository_name_valid('git3-ly')
	assert is_repository_name_valid('git3ly_')
	assert is_repository_name_valid('git-ly')

	assert is_repository_name_valid('_gitly') == false
	assert is_repository_name_valid('1gitly') == false
	assert is_repository_name_valid('') == false
	assert is_repository_name_valid(' ') == false
	assert is_repository_name_valid(' 33') == false
	assert is_repository_name_valid(' gitly') == false
	assert is_repository_name_valid('#gitly') == false
}

fn test_is_string_empty() {
	assert is_string_empty('')

	assert is_string_empty(' ')

	assert is_string_empty('g') == false

	assert is_string_empty(' g') == false
}
