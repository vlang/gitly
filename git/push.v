module git

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
