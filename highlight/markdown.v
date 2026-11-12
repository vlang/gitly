module highlight

import markdown

pub fn convert_markdown_to_html(code string) string {
	// Extract display-math blocks (...) before rendering so md4c does not
	// mangle them; re-inject them as <div class="math"> after sanitisation.
	code2, placeholders := extract_math_blocks(code)

	rendered := markdown.to_html(code2).trim_right('\n')

	// Raw HTML is disabled in the renderer, but Markdown links and images still
	// create href/src attributes. Keep relative links and an explicit allowlist
	// of network schemes; everything else (notably javascript: and data:) loses
	// the dangerous attribute.
	sanitized := sanitize_rendered_markdown_urls(rendered)

	return inject_math_blocks(sanitized, placeholders)
}

struct MathBlock {
	placeholder string
	html        string
}

fn extract_math_blocks(code string) (string, []MathBlock) {
	mut out := code
	mut blocks := []MathBlock{}
	mut i := 0
	delimiter := '$' + '$'
	mut placeholder_prefix := 'GITLY_MATH_BLOCK_'
	for out.contains(placeholder_prefix) {
		placeholder_prefix += '_'
	}
	for {
		start := out.index(delimiter) or { break }
		end := out.index_after_(delimiter, start + delimiter.len)
		if end < 0 {
			break
		}
		content := out[start + delimiter.len..end]
		placeholder := '${placeholder_prefix}${i}TOKEN'
		blocks << MathBlock{
			placeholder: placeholder
			html: '<div class="math">${escape_html(content.trim_space())}</div>'
		}
		out = out[..start] + placeholder + out[end + delimiter.len..]
		i++
	}
	return out, blocks
}

fn inject_math_blocks(html string, blocks []MathBlock) string {
	mut out := html
	for b in blocks {
		out = out.replace(b.placeholder, b.html)
	}
	return out
}

fn sanitize_rendered_markdown_urls(html string) string {
	mut out := html
	for attribute in ['href', 'src'] {
		needle := '${attribute}="'
		mut search_from := 0
		for {
			start := out.index_after_(needle, search_from)
			if start < 0 {
				break
			}
			value_start := start + needle.len
			rel_end := out[value_start..].index('"') or { break }
			value_end := value_start + rel_end
			value := out[value_start..value_end]
			if !is_safe_markdown_url(value) {
				out = out[..start] + out[value_end + 1..]
				search_from = start
				continue
			}
			search_from = value_end + 1
		}
	}
	return out
}

fn is_safe_markdown_url(value string) bool {
	trimmed := value.trim_space()
	if trimmed == '' || trimmed.starts_with('#') || trimmed.starts_with('/')
		|| trimmed.starts_with('./') || trimmed.starts_with('../') {
		return true
	}
	mut normalized_bytes := []u8{cap: trimmed.len}
	for ch in trimmed.to_lower().bytes() {
		if ch > 0x20 && ch != 0x7f {
			normalized_bytes << ch
		}
	}
	normalized := normalized_bytes.bytestr()
	colon := normalized.index(':') or { return true }
	boundary := normalized.index_any('/?#')
	if boundary >= 0 && boundary < colon {
		return true
	}
	scheme := normalized[..colon]
	return scheme in ['http', 'https', 'mailto']
}
