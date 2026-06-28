// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import highlight
import strings

fn render_diff_table(fd FileDiff) veb.RawHtml {
	mut out := strings.new_builder(1024)
	out.write_string('<div class=pr-diff__table>')
	for hunk in fd.hunks {
		out.write_string(diff_hunk_header_html(hunk.header))
		for dline in hunk.lines {
			out.write_string(diff_line_row_html(fd.path, dline))
		}
	}
	out.write_string('</div>')
	return veb.RawHtml(out.str())
}

fn diff_hunk_header_html(header string) string {
	return '<p class=h><code>${html_escape_text(header)}</code></p>'
}

fn diff_line_row_html(file_path string, dline DiffLine) string {
	return diff_line_row_html_with_attrs(file_path, dline, '')
}

fn diff_line_row_html_with_attrs(file_path string, dline DiffLine, attrs string) string {
	return '<p class=${dline.compact_class()}${attrs}><u>${dline.old_line_str()}</u><u>${dline.new_line_str()}</u><i>${dline.compact_sign()}</i><s>${highlight.highlight_line(dline.content,
		file_path)}</s></p>'
}

struct FileDiff {
mut:
	path       string
	old_path   string
	is_new     bool
	is_deleted bool
	is_renamed bool
	is_binary  bool
	additions  int
	deletions  int
	hunks      []DiffHunk
}

struct DiffHunk {
mut:
	header    string
	old_start int
	old_count int
	new_start int
	new_count int
	lines     []DiffLine
}

struct DiffLine {
mut:
	kind     string // 'context', 'add', 'del'
	old_line int    // 0 if not applicable
	new_line int    // 0 if not applicable
	content  string
}

// parse_unified_diff parses a `git diff` unified diff into FileDiff structs.
fn parse_unified_diff(raw string) []FileDiff {
	mut files := []FileDiff{}
	mut cur := FileDiff{}
	mut cur_hunk := DiffHunk{}
	mut in_file := false
	mut in_hunk := false
	mut old_l := 0
	mut new_l := 0

	for line in raw.split_into_lines() {
		if line.starts_with('diff --git') {
			if in_file {
				if in_hunk {
					cur.hunks << cur_hunk
				}
				files << cur
			}
			cur = FileDiff{}
			cur_hunk = DiffHunk{}
			in_file = true
			in_hunk = false
			parts := line.split(' ')
			if parts.len >= 4 {
				a_path := strip_diff_prefix(parts[2], 'a/')
				b_path := strip_diff_prefix(parts[3], 'b/')
				cur.old_path = a_path
				cur.path = b_path
			}
		} else if line.starts_with('new file') {
			cur.is_new = true
		} else if line.starts_with('deleted file') {
			cur.is_deleted = true
		} else if line.starts_with('rename from') || line.starts_with('rename to') {
			cur.is_renamed = true
		} else if line.starts_with('Binary files') {
			cur.is_binary = true
		} else if line.starts_with('--- ') || line.starts_with('+++ ') {
			// skip header lines
		} else if line.starts_with('@@') {
			if in_hunk {
				cur.hunks << cur_hunk
			}
			cur_hunk = DiffHunk{
				header: line
			}
			in_hunk = true
			parse_hunk_header(line, mut cur_hunk)
			old_l = cur_hunk.old_start
			new_l = cur_hunk.new_start
		} else if in_hunk && line.len > 0 {
			first := line[0]
			content := line[1..]
			if first == ` ` {
				cur_hunk.lines << DiffLine{
					kind:     'context'
					old_line: old_l
					new_line: new_l
					content:  content
				}
				old_l++
				new_l++
			} else if first == `+` {
				cur_hunk.lines << DiffLine{
					kind:     'add'
					new_line: new_l
					content:  content
				}
				new_l++
				cur.additions++
			} else if first == `-` {
				cur_hunk.lines << DiffLine{
					kind:     'del'
					old_line: old_l
					content:  content
				}
				old_l++
				cur.deletions++
			} else if first == `\\` {
				// "\ No newline at end of file" — ignore
			}
		}
	}
	if in_file {
		if in_hunk {
			cur.hunks << cur_hunk
		}
		files << cur
	}
	return files
}

fn (d &DiffLine) compact_sign() string {
	return match d.kind {
		'add' { '+' }
		'del' { '-' }
		else { '' }
	}
}

fn (d &DiffLine) compact_class() string {
	return match d.kind {
		'add' { 'a' }
		'del' { 'd' }
		else { 'c' }
	}
}

fn (d &DiffLine) compact_side() string {
	return match d.kind {
		'add' { 'n' }
		'del' { 'o' }
		else { '' }
	}
}

fn (d &DiffLine) side() string {
	return if d.kind == 'add' { 'new' } else { 'old' }
}

fn (d &DiffLine) effective_line() int {
	return if d.kind == 'add' { d.new_line } else { d.old_line }
}

fn (d &DiffLine) comment_field_name(file_path string) string {
	return 'rc::${file_path}::${d.side()}::${d.effective_line()}'
}

fn (d &DiffLine) old_line_str() string {
	return if d.old_line > 0 { d.old_line.str() } else { '' }
}

fn (d &DiffLine) new_line_str() string {
	return if d.new_line > 0 { d.new_line.str() } else { '' }
}

fn strip_diff_prefix(s string, prefix string) string {
	if s.starts_with(prefix) {
		return s[prefix.len..]
	}
	return s
}

// parse_hunk_header parses lines like "@@ -1,3 +1,4 @@ optional context"
fn parse_hunk_header(line string, mut hunk DiffHunk) {
	parts := line.split(' ')
	for p in parts {
		if p.len < 2 {
			continue
		}
		if p[0] == `-` {
			start, count := parse_range(p[1..])
			hunk.old_start = start
			hunk.old_count = count
		} else if p[0] == `+` {
			start, count := parse_range(p[1..])
			hunk.new_start = start
			hunk.new_count = count
		}
	}
}

fn parse_range(s string) (int, int) {
	idx := s.index(',') or { return s.int(), 1 }
	return s[..idx].int(), s[idx + 1..].int()
}
