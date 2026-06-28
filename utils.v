module main

import time
import math
import os
import veb

pub fn (mut app App) running_since() string {
	duration := time.now().unix() - app.started_at

	seconds_in_hour := 60 * 60

	days := int(math.floor(f64(duration) / f64(seconds_in_hour * 24)))
	hours := int(math.fmod(math.floor(f64(duration) / f64(seconds_in_hour)), 24))
	minutes := int(math.floor(f64(duration) / 60.0)) % 60
	seconds := duration % 60

	return '${days} days ${hours} hours ${minutes} minutes and ${seconds} seconds'
}

pub fn (mut ctx Context) make_path(branch_name string, i int) string {
	if i == 0 {
		return ctx.path_split[..i + 1].join('/')
	}
	mut s := ctx.path_split[0]
	s += '/tree/${branch_name}/'
	s += ctx.path_split[1..i + 1].join('/')
	return s
}

fn create_directory_if_not_exists(path string) {
	if !os.exists(path) {
		os.mkdir(path) or { panic('cannot create ${path} directory') }
	}
}

fn calculate_pages(count int, per_page int) int {
	if count == 0 {
		return 0
	}

	return int(math.ceil(f32(count) / f32(per_page))) - 1
}

fn generate_prev_next_pages(page int) (int, int) {
	prev_page := if page > 0 { page - 1 } else { 0 }
	next_page := page + 1

	return prev_page, next_page
}

fn check_first_page(page int) bool {
	return page == 0
}

fn check_last_page(total int, offset int, per_page int) bool {
	return (total - offset) < per_page
}

const is_dev = true

fn css2(s string) veb.RawHtml {
	if is_dev {
		return '<link href="http://localhost:8000/${s}" rel="stylesheet" type="text/css">'
	} else {
		return '<link href="/static/${s}" rel="stylesheet" type="text/css">'
	}
}

fn minify_pr_files_html(mut ctx Context) bool {
	if ctx.res.body.len == 0 {
		return true
	}
	minified := strip_intertag_whitespace(ctx.res.body)
	if minified.len != ctx.res.body.len {
		ctx.res.body = minified
		ctx.res.header.set(.content_length, ctx.res.body.len.str())
	}
	return true
}

fn strip_intertag_whitespace(s string) string {
	mut out := []u8{cap: s.len}
	mut i := 0
	mut preserve_whitespace_depth := 0
	for i < s.len {
		ch := s[i]
		if ch == `<` {
			tag_end := html_tag_end(s, i)
			if tag_end == -1 {
				out << ch
				i++
				continue
			}
			tag_name, closing, self_closing := html_tag_info(s, i, tag_end)
			compact_tag := compact_html_tag(s, i, tag_end)
			for k := 0; k < compact_tag.len; k++ {
				out << compact_tag[k]
			}
			if preserves_html_whitespace(tag_name) {
				if closing {
					if preserve_whitespace_depth > 0 {
						preserve_whitespace_depth--
					}
				} else if !self_closing {
					preserve_whitespace_depth++
				}
			}
			i = tag_end + 1
			continue
		}
		if is_html_space(ch) {
			mut j := i + 1
			mut has_indentation := ch != ` `
			for j < s.len && is_html_space(s[j]) {
				if s[j] != ` ` {
					has_indentation = true
				}
				j++
			}
			prev_is_tag_end := out.len > 0 && out[out.len - 1] == `>`
			next_is_tag_start := j < s.len && s[j] == `<`
			should_strip := preserve_whitespace_depth == 0
				&& ((prev_is_tag_end && next_is_tag_start)
				|| (has_indentation && (prev_is_tag_end || next_is_tag_start)))
			if should_strip {
				i = j
				continue
			}
			if preserve_whitespace_depth == 0 && has_indentation {
				out << ` `
			} else {
				for k := i; k < j; k++ {
					out << s[k]
				}
			}
			i = j
			continue
		}
		out << ch
		i++
	}
	return out.bytestr()
}

fn compact_html_tag(s string, start int, end int) string {
	mut out := []u8{cap: end - start + 1}
	mut i := start
	for i <= end {
		ch := s[i]
		if ch == `"` || ch == `'` {
			quote := ch
			out << ch
			mut value_end := i + 1
			for value_end <= end && s[value_end] != quote {
				value_end++
			}
			if value_end <= end {
				mut value_start := i + 1
				mut value_finish := value_end
				for value_start < value_finish && is_html_space(s[value_start]) {
					value_start++
				}
				for value_finish > value_start && is_html_space(s[value_finish - 1]) {
					value_finish--
				}
				for k := value_start; k < value_finish; k++ {
					out << s[k]
				}
				out << quote
				i = value_end + 1
				continue
			}
		}
		out << ch
		i++
	}
	return out.bytestr()
}

fn html_tag_end(s string, start int) int {
	mut quote := u8(0)
	for i := start + 1; i < s.len; i++ {
		ch := s[i]
		if quote != 0 {
			if ch == quote {
				quote = 0
			}
		} else if ch == `"` || ch == `'` {
			quote = ch
		} else if ch == `>` {
			return i
		}
	}
	return -1
}

fn html_tag_info(s string, start int, end int) (string, bool, bool) {
	mut i := start + 1
	mut closing := false
	if i < end && s[i] == `/` {
		closing = true
		i++
	}
	for i < end && is_html_space(s[i]) {
		i++
	}
	name_start := i
	for i < end && is_html_tag_name_char(s[i]) {
		i++
	}
	name := s[name_start..i].to_lower()
	mut j := end - 1
	for j > start && is_html_space(s[j]) {
		j--
	}
	self_closing := !closing && j > start && s[j] == `/`
	return name, closing, self_closing
}

fn preserves_html_whitespace(tag_name string) bool {
	return tag_name in ['s', 'pre', 'textarea', 'script', 'style']
}

fn is_html_tag_name_char(ch u8) bool {
	return (ch >= `a` && ch <= `z`) || (ch >= `A` && ch <= `Z`)
		|| (ch >= `0` && ch <= `9`) || ch == `-` || ch == `_` || ch == `:`
}

fn is_html_space(ch u8) bool {
	return ch == ` ` || ch == `\n` || ch == `\t` || ch == `\r`
}
