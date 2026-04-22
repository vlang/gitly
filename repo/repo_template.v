module main

import veb

fn get_declension_form(count int, first_form string, second_form string) string {
	if count == 1 {
		return '<b>${count}</b> ${first_form}'
	}

	return '<b>${count}</b> ${second_form}'
}

fn (mut app App) format_commits_count(repo Repo, branch_name string) veb.RawHtml {
	branch := app.find_repo_branch_by_name(repo.id, branch_name)
	nr_commits := app.get_repo_commit_count(repo.id, branch.id)

	return get_declension_form(nr_commits, 'Commit', 'Commits')
}

fn (r &Repo) format_nr_branches() veb.RawHtml {
	return get_declension_form(r.nr_branches, 'Branch', 'Branches')
}

fn (r &Repo) format_nr_tags() veb.RawHtml {
	return get_declension_form(r.nr_tags, 'Branch', 'Branches')
}

fn (r &Repo) format_nr_open_prs() veb.RawHtml {
	return get_declension_form(r.nr_open_prs, 'Pull request', 'Pull requests')
}

fn (r &Repo) format_nr_open_issues() veb.RawHtml {
	return get_declension_form(r.nr_open_issues, 'Issue', 'Issues')
}

fn (r &Repo) format_nr_contributors() veb.RawHtml {
	return get_declension_form(r.nr_contributors, 'Contributor', 'Contributors')
}

fn (r &Repo) format_nr_topics() veb.RawHtml {
	return get_declension_form(r.nr_topics, 'Discussion', 'discussions')
}

fn (r &Repo) format_nr_releases() veb.RawHtml {
	return get_declension_form(r.nr_releases, 'Release', 'Releases')
}
