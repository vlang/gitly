module main

import vweb

fn get_declension_form(count int, first_form string, second_form string) string {
	if count == 1 {
		return '<b>1</b> $first_form'
	}

	return '<b>$count</b> $second_form'
}

fn (mut app App) format_commits_count(repo Repo, branch_name string) vweb.RawHtml {
	branch := app.find_repo_branch_by_name(repo.id, branch_name)
	commits_count := app.get_repo_commit_count(repo.id, branch.id)

	return get_declension_form(commits_count, 'commit', 'commits')
}

fn (r &Repo) format_branches_count() vweb.RawHtml {
	return get_declension_form(r.branches_count, 'branch', 'branches')
}

fn (r &Repo) format_open_prs_count() vweb.RawHtml {
	return get_declension_form(r.open_prs_count, 'pull request', 'pull requests')
}

fn (r &Repo) format_open_issues_count() vweb.RawHtml {
	return get_declension_form(r.open_issues_count, 'issue', 'issues')
}

fn (r &Repo) format_contributors_count() vweb.RawHtml {
	return get_declension_form(r.contributors_count, 'contributor', 'contributors')
}

fn (r &Repo) format_topics_count() vweb.RawHtml {
	return get_declension_form(r.topics_count, 'discussion', 'discussions')
}

fn (r &Repo) format_releases_count() vweb.RawHtml {
	return get_declension_form(r.releases_count, 'release', 'releases')
}
