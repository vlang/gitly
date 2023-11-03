// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module highlight

const (
	tab = '    ' //        '
)

// returns HTML code, number of lines, number of lines with source code
pub fn highlight_text(st string, file_path string, commit bool) (string, int, int) {
	if !commit {
		file_extension := extract_extension_from_file_path(file_path)

		if file_extension == 'md' {
			return convert_markdown_to_html(st), 0, 0
		} else if file_extension == 'txt' {
			return st, 0, 0
		}
	}

	lang := extension_to_lang(file_path) or { Lang{} }
	text := '${st} '
	mut res := []u8{cap: text.len}
	mut lines := 0
	mut sloc := 0
	mut ss := u8(` `)
	lc := lang.line_comments
	mut mlc := ''
	mut mlc_end := ''
	if lang.mline_comments.len >= 2 {
		mlc = lang.mline_comments[0]
		mlc_end = lang.mline_comments[1]
	}
	res << '<table class="hl_table">'.bytes()
	res << `\n`
	if !is_single_line(st) {
		res << '<tr><td><a id="1" class="no_select" href="#1">1</a></td><td>'.bytes()
		lines++
	}
	mut in_comment := false
	mut in_line_comment := false
	mut in_string := false
	mut runes := text.bytes()
	for pos := 0; pos < runes.len - 1; pos++ {
		mut c := runes[pos]
		if c == `\n` {
			lines++
			if commit {
				mut class := ''
				if runes[pos + 1] == `+` {
					class = 'class="a"'
				} else if runes[pos + 1] == `-` {
					class = 'class="d"'
				}
				res << '</td></tr>\n<tr><td><a id="${lines}" class="no_select" href="#${lines}">${lines}</a></td><td ${class}>'.bytes()
			} else {
				res << '</td></tr>\n<tr><td><a id="${lines}" class="no_select" href="#${lines}">${lines}</a></td><td>'.bytes()
			}
			if in_line_comment {
				in_line_comment = false
				res << '</i>'.bytes()
			}
			if in_comment {
				res << '<i>'.bytes()
			}
			if !in_comment && !in_line_comment && runes[pos + 1] != `\n` {
				sloc++
			}
			continue
		}
		if c == `\t` {
			res << highlight.tab.bytes()
			continue
		}
		if in_comment {
			res << write(c)
			if c == mlc_end[0] && is_line_comment(runes, pos, mlc_end) {
				in_comment = false
				res << runes[pos + 1]
				pos++
				res << '</i>'.bytes()
			}
			continue
		}
		if in_line_comment {
			res << write(c)
			continue
		}
		if in_string {
			res << write(c)
			if runes[pos - 1] == `\\` && ss == `"` {
				continue
			}
			if c == ss {
				in_string = false
				res << '</u>'.bytes()
			}
			continue
		}
		if is_letter(c, lang) {
			word_start := pos
			for is_letter(c, lang) {
				pos++
				c = runes[pos]
			}
			delta := pos - word_start
			mut data := []u8{}
			for i in 0 .. delta {
				data << runes[word_start + i]
			}
			w := data.bytestr()
			pos--
			if w in lang.keywords {
				res << '<b>${w}</b>'.bytes()
			} else {
				res << w.bytes()
			}
			continue
		}
		if is_string_token(c, lang) {
			in_string = true
			ss = c
			res << '<u>'.bytes()
		} else if mlc != '' && c == mlc.bytes()[0] && is_line_comment(runes, pos, mlc) {
			in_comment = true
			res << '<i>'.bytes()
		} else if lc != '' && c == lc.bytes()[0] && is_line_comment(runes, pos, lc) {
			in_line_comment = true
			res << '<i>'.bytes()
		}
		res << write(c)
	}
	res << '</tr>'.bytes()
	res << '</table>'.bytes()
	return res.bytestr(), lines, sloc
}

fn write(c u8) []u8 {
	mut tmp := []u8{}
	if c == `<` {
		tmp << '&lt;'.bytes()
	} else if c == `>` {
		tmp << '&gt;'.bytes()
	} else {
		tmp << c
	}
	return tmp
}

fn is_letter(c u8, lang Lang) bool {
	name := lang.name.to_lower()
	if (name == 'cpp' || name == 'c' || name == 'd' || name == 'swift') && c == `#` {
		return true
	}
	return c.is_letter() || c == `_`
}

fn is_string_token(c u8, lang Lang) bool {
	for val in lang.string_start {
		if c == val[0] {
			return true
		}
	}
	return false
}

fn is_line_comment(s []u8, pos int, lc string) bool {
	for i, b in lc {
		if s[pos + i] != b {
			return false
		}
	}
	return true
}

fn is_single_line(s string) bool {
	mut cnt := 0
	for i in 0 .. s.len {
		if s[i] == `\n` {
			cnt++
			if cnt > 1 {
				return false
			}
		}
	}
	return true
}

fn extract_extension_from_file_path(path string) string {
	return path.split('.').last().to_lower()
}
