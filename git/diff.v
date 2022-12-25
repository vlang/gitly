module git

pub enum DiffFileStatus {
	added
	copied
	deleted
	modified
	renamed
	type_changed // (regular file, symbolic link or submodule)
	unmerged // (you must complete the merge before it can be committed)
	unknown
}

pub struct DiffFile {
pub:
	status           DiffFileStatus
	original_path    string
	destination_path string
}

pub fn parse_diff_output(output string) []DiffFile {
	mut changes := []DiffFile{}

	for diff in output.trim_space().split_into_lines() {
		diff_parts := diff.split('\t')

		status := diff_parts[0]
		// Status letters C and R are always followed by a score (denoting the percentage of similarity between the source and target of the move or copy).
		// Status letter M may be followed by a score (denoting the percentage of dissimilarity) for file rewrites.
		statue_letter := status[0]
		original_path := diff_parts[1]
		destination_path := diff_parts[2] or { '' }

		match statue_letter {
			`A` {
				changes << DiffFile{
					status: DiffFileStatus.added
					original_path: original_path
				}
			}
			`C` {
				changes << DiffFile{
					status: DiffFileStatus.copied
					original_path: original_path
					destination_path: destination_path
				}
			}
			`D` {
				changes << DiffFile{
					status: DiffFileStatus.deleted
					original_path: original_path
				}
			}
			`M` {
				changes << DiffFile{
					status: DiffFileStatus.modified
					original_path: original_path
				}
			}
			`R` {
				changes << DiffFile{
					status: DiffFileStatus.renamed
					original_path: original_path
					destination_path: destination_path
				}
			}
			`T` {
				changes << DiffFile{
					status: DiffFileStatus.type_changed
					original_path: original_path
				}
			}
			`U` {
				changes << DiffFile{
					status: DiffFileStatus.unmerged
				}
			}
			`X` {
				changes << DiffFile{
					status: DiffFileStatus.unknown
				}
			}
			else {
				continue
			}
		}
	}

	return changes
}
