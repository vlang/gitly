module highlight

const xss_markdown_sample = '<script>  alert(true) </script> <!--  comment -->test'

fn test_convert_markdown_to_html() {
	rendered := convert_markdown_to_html(xss_markdown_sample)
	assert !rendered.contains('<script>')
	assert rendered.contains('&lt;script&gt;')
	assert rendered.contains('test</p>')
}

fn test_convert_markdown_table_to_html() {
	markdown_table := '| V full version | V 0.5.1 |\n|:----------------|:--------|\n| OS | linux |\n'
	rendered := convert_markdown_to_html(markdown_table)

	assert rendered.contains('<table>')
	assert rendered.contains('<thead>')
	assert rendered.contains('<th align="left">V full version</th>')
	assert rendered.contains('<td align="left">linux</td>')
}

fn test_convert_markdown_blocks_raw_html_xss() {
	for payload in [
		'<img src=x onerror=alert(1)>',
		'<svg><script>alert(1)</script></svg>',
		'<a href="javascript:alert(1)">click</a>',
	] {
		rendered := convert_markdown_to_html(payload)
		assert !rendered.contains('<script')
		assert !rendered.contains('<svg')
		assert !rendered.contains('<img')
		assert !rendered.contains('href="javascript:')
	}
}

fn test_convert_markdown_filters_unsafe_link_schemes() {
	assert !is_safe_markdown_url('javascript:alert(1)')
	assert sanitize_rendered_markdown_urls('<a href="javascript:alert(1)">x</a>') == '<a >x</a>'
	unsafe_link := convert_markdown_to_html('[click](javascript:alert(1))')
	unsafe_image := convert_markdown_to_html('![image](data:text/html;base64,PHNjcmlwdD4=)')
	safe_link := convert_markdown_to_html('[site](https://example.com/path)')
	relative_link := convert_markdown_to_html('[readme](../README.md)')

	assert !unsafe_link.contains('href=')
	assert !unsafe_image.contains('src=')
	assert safe_link.contains('href="https://example.com/path"')
	assert relative_link.contains('href="../README.md"')
}

fn test_plain_text_highlighting_escapes_html() {
	rendered, _, _ := highlight_text('<img src=x onerror=alert(1)>', 'notes.txt', false)
	assert rendered == '&lt;img src=x onerror=alert(1)&gt;'
}
