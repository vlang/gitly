module main

import time
import veb

const admin_stats_days = 30
const stats_month_short = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct',
	'Nov', 'Dec']

struct DayBucket {
	label string
	count int
}

struct AdminStats {
mut:
	days          int
	users         []DayBucket
	repos         []DayBucket
	commits       []DayBucket
	issues        []DayBucket
	total_users   int
	total_repos   int
	total_commits int
	total_issues  int
	max_users     int
	max_repos     int
	max_commits   int
	max_issues    int
}

fn stats_day_label(ts i64) string {
	t := time.unix(ts)
	return '${stats_month_short[t.month - 1]} ${t.day}'
}

fn stats_bucket_index(ts i64, range_start i64, one_day i64, days int) int {
	if ts < range_start {
		return -1
	}
	idx := int((ts - range_start) / one_day)
	if idx < 0 || idx >= days {
		return -1
	}
	return idx
}

pub fn (mut app App) get_admin_stats(days int) AdminStats {
	one_day := i64(86400)
	today_start := time.now().unix() / one_day * one_day
	range_start := today_start - i64(days - 1) * one_day

	mut user_counts := []int{len: days, init: 0}
	mut repo_counts := []int{len: days, init: 0}
	mut commit_counts := []int{len: days, init: 0}
	mut issue_counts := []int{len: days, init: 0}

	registered_users := sql app.db {
		select from User where is_registered == true
	} or { []User{} }
	for u in registered_users {
		idx := stats_bucket_index(u.created_at.unix(), range_start, one_day, days)
		if idx >= 0 {
			user_counts[idx]++
		}
	}

	repo_rows := db_exec_values(mut app.db,
		'select created_at from ${sql_table('Repo')} where created_at >= ${range_start}') or {
		[][]string{}
	}
	for row in repo_rows {
		if row.len == 0 {
			continue
		}
		idx := stats_bucket_index(row[0].i64(), range_start, one_day, days)
		if idx >= 0 {
			repo_counts[idx]++
		}
	}

	commit_rows := db_exec_values(mut app.db,
		'select created_at from ${sql_table('Commit')} where created_at >= ${range_start}') or {
		[][]string{}
	}
	for row in commit_rows {
		if row.len == 0 {
			continue
		}
		idx := stats_bucket_index(row[0].i64(), range_start, one_day, days)
		if idx >= 0 {
			commit_counts[idx]++
		}
	}

	issue_rows := db_exec_values(mut app.db,
		'select created_at from ${sql_table('Issue')} where is_pr is false and created_at >= ${range_start}') or {
		[][]string{}
	}
	for row in issue_rows {
		if row.len == 0 {
			continue
		}
		idx := stats_bucket_index(row[0].i64(), range_start, one_day, days)
		if idx >= 0 {
			issue_counts[idx]++
		}
	}

	mut user_series := []DayBucket{cap: days}
	mut repo_series := []DayBucket{cap: days}
	mut commit_series := []DayBucket{cap: days}
	mut issue_series := []DayBucket{cap: days}
	mut max_u := 0
	mut max_r := 0
	mut max_c := 0
	mut max_i := 0
	for i in 0 .. days {
		ts := range_start + i64(i) * one_day
		lbl := stats_day_label(ts)
		user_series << DayBucket{lbl, user_counts[i]}
		repo_series << DayBucket{lbl, repo_counts[i]}
		commit_series << DayBucket{lbl, commit_counts[i]}
		issue_series << DayBucket{lbl, issue_counts[i]}
		if user_counts[i] > max_u {
			max_u = user_counts[i]
		}
		if repo_counts[i] > max_r {
			max_r = repo_counts[i]
		}
		if commit_counts[i] > max_c {
			max_c = commit_counts[i]
		}
		if issue_counts[i] > max_i {
			max_i = issue_counts[i]
		}
	}

	total_users := sql app.db {
		select count from User where is_registered == true
	} or { 0 }
	total_repos := sql app.db {
		select count from Repo
	} or { 0 }
	total_commits := sql app.db {
		select count from Commit
	} or { 0 }
	total_issues := sql app.db {
		select count from Issue where is_pr == false
	} or { 0 }

	return AdminStats{
		days:          days
		users:         user_series
		repos:         repo_series
		commits:       commit_series
		issues:        issue_series
		total_users:   total_users
		total_repos:   total_repos
		total_commits: total_commits
		total_issues:  total_issues
		max_users:     max_u
		max_repos:     max_r
		max_commits:   max_c
		max_issues:    max_i
	}
}

fn render_stat_chart(buckets []DayBucket, max int, color string) veb.RawHtml {
	chart_w := 720
	chart_h := 200
	bar_area_h := 160
	bar_top := 10
	bar_count := buckets.len
	if bar_count == 0 {
		return veb.RawHtml('')
	}
	slot := (chart_w - 20) / bar_count
	bar_w := if slot > 4 { slot - 2 } else { slot }
	mut s := '<svg class="stat-chart" viewBox="0 0 ${chart_w} ${chart_h}" preserveAspectRatio="none">'
	s += '<g class="stat-chart-grid">'
	for i in 1 .. 5 {
		y := bar_top + bar_area_h - bar_area_h * i / 4
		s += '<line x1="10" y1="${y}" x2="${chart_w - 10}" y2="${y}"></line>'
	}
	s += '</g>'
	for i, b in buckets {
		h := if max == 0 { 0 } else { b.count * bar_area_h / max }
		x := 10 + i * slot
		y := bar_top + bar_area_h - h
		s += '<rect class="stat-chart-bar" x="${x}" y="${y}" width="${bar_w}" height="${h}" fill="${color}">'
		s += '<title>${b.label}: ${b.count}</title></rect>'
	}
	label_y := chart_h - 6
	for i, b in buckets {
		if i % 5 == 0 || i == buckets.len - 1 {
			x := 10 + i * slot + bar_w / 2
			s += '<text class="stat-chart-label" x="${x}" y="${label_y}" text-anchor="middle">${b.label}</text>'
		}
	}
	s += '</svg>'
	return veb.RawHtml(s)
}
