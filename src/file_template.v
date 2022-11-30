module main

import vweb
import regex

fn replace_issue_id(re regex.RE, in_txt string, _ int, _ int) string {
	issue_id := re.get_group_by_id(in_txt, 0)

	return in_txt.replace(issue_id, '<a class="issue-id-anchor" href="#">${issue_id}</a>')
}

fn (f File) format_commit_message() vweb.RawHtml {
	id_query := r'(#\d+)'
	mut re := regex.regex_opt(id_query) or { panic(err) }

	return re.replace_by_fn(f.last_msg, replace_issue_id)
}
