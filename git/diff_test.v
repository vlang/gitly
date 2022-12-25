module git

fn test_parse_diff_output() {
	output := '
A	.editorconfig
M	README.md
D	gitly.v
R070	hl/hl.v	highlight/highlight.v
A	validation/validation_service.v
D	commit.v
'

	diff_files := parse_diff_output(output)

	assert diff_files.len == 6

	assert diff_files[0].status == .added
	assert diff_files[0].original_path == '.editorconfig'

	assert diff_files[1].status == .modified
	assert diff_files[1].original_path == 'README.md'

	assert diff_files[2].status == .deleted
	assert diff_files[2].original_path == 'gitly.v'

	assert diff_files[3].status == .renamed
	assert diff_files[3].original_path == 'hl/hl.v'
	assert diff_files[3].destination_path == 'highlight/highlight.v'

	assert diff_files[4].status == .added
	assert diff_files[4].original_path == 'validation/validation_service.v'

	assert diff_files[5].status == .deleted
	assert diff_files[5].original_path == 'commit.v'
}
