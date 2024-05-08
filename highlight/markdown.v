module highlight

import markdown
import pcre

const allowed_tags = [
	'a',
	'abbr',
	'b',
	'blockquote',
	'body',
	'br',
	'center',
	'code',
	'dd',
	'details',
	'div',
	'dl',
	'dt',
	'em',
	'font',
	'h1',
	'h2',
	'h3',
	'h4',
	'h5',
	'h6',
	'hr',
	'i',
	'img',
	'kbd',
	'label',
	'li',
	'ol',
	'p',
	'pre',
	'small',
	'source',
	'span',
	'strong',
	'sub',
	'summary',
	'sup',
	'table',
	'tbody',
	'tr',
	'td',
	'th',
	'thead',
	'ul',
	'u',
	'video',
]
const allowed_attributes = [
	'align',
	'color',
	'controls',
	'height',
	'href',
	'id',
	'src',
	'style',
	'target',
	'title',
	'type',
	'width',
]
const unallowed_schemas = [
	'javascript:',
]

pub fn convert_markdown_to_html(code string) string {
	markdown_code := sanitize_markdown_code(code)

	return markdown.to_html(markdown_code)
}

// temporary solution while markdown module doesn't support
// sanitizing HTML tags with DOM parsing
pub fn sanitize_markdown_code(code string) string {
	mut result := code

	result = remove_comments(result)
	result = sanitize_html_tags(result)

	return result
}

fn sanitize_html_tags(code string) string {
	mut result := code
	// tag name, attributes, tag content(optional)
	paired_tags_re := r'<[\s]*?(?<tag>[a-zA-Z0-9]*)(.*?)>([\s\S]*?)<\/\s*?\g{tag}*?\s*?>'
	unpaired_tags_re := r'<(\w*)\s+(.*?)()>'

	result = sanitize_html_tags_with_re(paired_tags_re, result)
	result = sanitize_html_tags_with_re(unpaired_tags_re, result)

	return result
}

fn sanitize_html_tags_with_re(re string, code string) string {
	mut result := code

	tags_re := pcre.new_regex(re, 0) or {
		println(err)
		return result
	}

	mut last_found_index := 0

	for {
		matched := tags_re.match_str(result, last_found_index, 0) or { break }
		tag := matched.get(0) or { continue }

		matched_start_index := result.index_after(tag, last_found_index)
		last_found_index = matched_start_index + tag.len

		tag_parts := matched.get_all()
		tag_name := tag_parts[0].trim_space().to_lower()
		tag_attributes := tag_parts[1].trim_space()
		tag_content := tag_parts[2].trim_space()
		is_allowed_tag := highlight.allowed_tags.contains(tag_name)

		if !is_allowed_tag {
			result = result.replace(tag, '')
			last_found_index = matched_start_index
		}

		sanitized_attributes := sanitize_html_attributes(tag_attributes)
		is_attributes_length_equal := tag_attributes.len == sanitized_attributes.len

		if !is_attributes_length_equal {
			result = result.replace(tag, tag.replace(tag_attributes, sanitized_attributes))
			difference := tag_attributes.len - sanitized_attributes.len
			last_found_index -= difference
		}

		sanitized_content := sanitize_html_tags(tag_content)
		is_content_length_equal := tag_content.len == sanitized_content.len

		if !is_content_length_equal {
			result = result.replace(tag, tag.replace(tag_content, sanitized_content))
			difference := tag_content.len - sanitized_content.len
			last_found_index -= difference
		}
	}

	tags_re.free()

	return result
}

fn sanitize_html_attributes(attributes string) string {
	mut result := attributes

	attributes_query := r'(\w+)[\s\S]*?=["]([\s\S]*?)["]'
	attributes_re := pcre.new_regex(attributes_query, 0) or {
		println(err)
		return result
	}

	mut last_found_index := 0

	for {
		matched := attributes_re.match_str(result, last_found_index, 0) or { break }
		attribute := matched.get(0) or { break }

		matched_start_index := result.index_after(attribute, last_found_index)
		last_found_index += matched_start_index + attribute.len

		attribute_parts := matched.get_all()
		attribute_name := attribute_parts[0].trim_space().to_lower()
		attribute_value := attribute_parts[1].trim_space()

		is_allowed_attribute := highlight.allowed_attributes.contains(attribute_name)
		is_unallowed_schemas := highlight.unallowed_schemas.any(attribute_value.starts_with(it))

		if !is_allowed_attribute || is_unallowed_schemas {
			result = result.replace(attribute, '')
			last_found_index -= attribute.len
		}
	}

	return result
}

fn remove_comments(code string) string {
	mut result := code

	remove_comments_query := r'<!--[\S\s]*?-->'
	remove_comments_re := pcre.new_regex(remove_comments_query, 0) or {
		println(err)
		return result
	}

	for {
		matched := remove_comments_re.match_str(result, 0, 0) or { break }
		comment := matched.get(0) or { break }
		result = result.replace(comment, '')
	}

	remove_comments_re.free()

	return result
}
