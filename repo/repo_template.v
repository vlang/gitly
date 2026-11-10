module main

import veb
import git

fn pick_plural_form(count int, forms []string, lang Lang) string {
	if forms.len == 1 {
		return forms[0]
	}
	n := if count < 0 { -count } else { count }
	if forms.len == 2 || lang != .ru {
		return if n == 1 { forms[0] } else { forms[1] }
	}
	last_two := n % 100
	last := n % 10
	if last_two >= 11 && last_two <= 14 {
		return forms[2]
	}
	if last == 1 {
		return forms[0]
	}
	if last >= 2 && last <= 4 {
		return forms[1]
	}
	return forms[2]
}

fn format_thousands(n int) string {
	s := n.str()
	mut neg := false
	mut digits := s
	if s.starts_with('-') {
		neg = true
		digits = s[1..]
	}
	if digits.len <= 3 {
		return s
	}
	mut out := ''
	first := digits.len % 3
	if first > 0 {
		out = digits[..first]
	}
	for i := first; i < digits.len; i += 3 {
		if out.len > 0 {
			out += ' '
		}
		out += digits[i..i + 3]
	}
	return if neg { '-' + out } else { out }
}

fn format_count(count int, key string, lang Lang) veb.RawHtml {
	s := veb.tr(lang.str(), key).trim_space()
	forms := s.split('|')
	form := pick_plural_form(count, forms, lang)
	return veb.RawHtml('<b>${format_thousands(count)}</b> ${form}')
}

fn (mut app App) format_commits_count(repo Repo, branch_name string, lang Lang) veb.RawHtml {
	branch := app.find_repo_branch_by_name(repo.id, branch_name)
	nr_commits := app.get_repo_commit_count(repo.id, branch.id)

	return format_count(nr_commits, 'commits_count', lang)
}

fn (r &Repo) format_nr_branches(lang Lang) veb.RawHtml {
	return format_count(r.nr_branches, 'branches_count', lang)
}

fn (r &Repo) format_nr_tags(lang Lang) veb.RawHtml {
	return format_count(r.nr_tags, 'tags_count', lang)
}

fn (r &Repo) format_nr_open_prs(lang Lang) veb.RawHtml {
	return format_count(r.nr_open_prs, 'prs_count', lang)
}

fn (r &Repo) format_nr_open_issues(lang Lang) veb.RawHtml {
	return format_count(r.nr_open_issues, 'issues_count', lang)
}

fn (r &Repo) format_nr_contributors(lang Lang) veb.RawHtml {
	return format_count(r.nr_contributors, 'contributors_count', lang)
}

fn (r &Repo) format_nr_releases(lang Lang) veb.RawHtml {
	return format_count(r.nr_releases, 'releases_count', lang)
}

fn (r &Repo) format_nr_stars(lang Lang) veb.RawHtml {
	return format_count(r.nr_stars, 'stars_count', lang)
}

fn (mut app App) format_nr_watchers(repo_id int, lang Lang) veb.RawHtml {
	return format_count(app.get_count_repo_watchers(repo_id), 'watchers_count', lang)
}

fn (r &Repo) format_size() veb.RawHtml {
	bytes := r.disk_size_bytes()
	if bytes <= 0 {
		return veb.RawHtml('')
	}
	num, unit := format_repo_size_parts(bytes)
	return veb.RawHtml('<b>${num}</b> ${unit}')
}

fn (r &Repo) disk_size_bytes() i64 {
	if r.git_dir == '' {
		return 0
	}
	result := git.Git.exec_in_dir(r.git_dir, ['count-objects', '-v'])
	if result.exit_code != 0 {
		return 0
	}
	mut total_kib := i64(0)
	for line in result.output.split_into_lines() {
		idx := line.index(':') or { continue }
		key := line[..idx].trim_space()
		if key != 'size' && key != 'size-pack' && key != 'size-garbage' {
			continue
		}
		total_kib += line[idx + 1..].trim_space().i64()
	}
	return total_kib * 1024
}

fn format_repo_size_parts(bytes i64) (string, string) {
	if bytes < 1024 {
		return bytes.str(), 'B'
	}
	if bytes < i64(1024) * 1024 {
		return (bytes / 1024).str(), 'KiB'
	}
	if bytes < i64(1024) * 1024 * 1024 {
		return (bytes / (i64(1024) * 1024)).str(), 'MiB'
	}
	tenths := (bytes * 10) / (i64(1024) * 1024 * 1024)
	return '${tenths / 10}.${tenths % 10}', 'GiB'
}
