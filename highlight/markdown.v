module highlight

import markdown
import regex

pub fn convert_markdown_to_html(code string) string {
	markdown_code := sanitize_markdown_code(code)

	return markdown.to_html(markdown_code)
}

// temporary solution while markdown module doesn't support sanitizing and escaping HTML tags
pub fn sanitize_markdown_code(code string) string {
	// FIXME: > in `sassc static/css/gitly.scss > static/css/gitly.css`
	remove_comments_query := r'<!--[\S\s]*?-->'
	mut remove_comments_re := regex.regex_opt(remove_comments_query) or { return code }
	code_no_comments := remove_comments_re.replace(code, '')

	return code_no_comments.replace_each(['<', '&lt;', '>', '&gt;'])
}
