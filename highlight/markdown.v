module highlight

import markdown

pub fn convert_markdown_to_html(code string) string {
	markdown_code := sanitize_markdown_code(code)

	return markdown.to_html(markdown_code)
}

// temporary solution while markdown module doesn't support sanitizing and escaping HTML tags
pub fn sanitize_markdown_code(code string) string {
	// FIXME: > in `sassc static/css/gitly.scss > static/css/gitly.css`
	// FIXME: remove comments <!-- -->
	return code.replace_each(['<', '&lt;', '>', '&gt;'])
}
