module main

import vweb

fn (r &Repo) format_commits_count() vweb.RawHtml {
	nr := r.commits_count

	if nr == 1 {
		return '<b>1</b> commit'
	}

	return '<b>$nr</b> commits'
}

fn (r &Repo) format_branches_count() vweb.RawHtml {
	nr := r.branches_count

	if nr == 1 {
		return '<b>1</b> branch'
	}

	return '<b>$nr</b> branches'
}

fn (r &Repo) format_open_prs_count() vweb.RawHtml {
	nr := r.open_prs_count

	if nr == 1 {
		return '<b>1</b> pull request'
	}

	return '<b>$nr</b> pull requests'
}

fn (r &Repo) format_open_issues_count() vweb.RawHtml {
	nr := r.open_issues_count

	if nr == 1 {
		return '<b>1</b> issue'
	}

	return '<b>$nr</b> issues'
}

fn (r &Repo) format_contributors_count() vweb.RawHtml {
	nr := r.contributors_count

	if nr == 1 {
		return '<b>1</b> contributor'
	}

	return '<b>$nr</b> contributors'
}

fn (r &Repo) format_topics_count() vweb.RawHtml {
	nr := r.topics_count

	if nr == 1 {
		return '<b>1</b> discussion'
	}

	return '<b>$nr</b> discussions'
}

fn (r &Repo) format_releases_count() vweb.RawHtml {
	nr := r.releases_count

	if nr == 1 {
		return '<b>1</b> release'
	}

	return '<b>$nr</b> releases'
}
