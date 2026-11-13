// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import veb
import highlight

struct Issue {
	id int @[primary; sql: serial]
mut:
	author_id             int
	repo_id               int
	is_pr                 bool
	assigned              []int   @[skip]
	labels                []Label @[skip]
	comments_count        int
	title                 string
	text                  string
	is_confidential       bool
	created_at            int
	status                IssueStatus
	linked_issues         []int @[skip]
	milestone_id          int
	iteration_id          int
	time_estimate_minutes int
	repo_author           string @[skip]
	repo_name             string @[skip]
}

enum IssueStatus {
	open   = 0
	closed = 1
}

struct Label {
	id int @[primary; sql: serial]
mut:
	repo_id int
	name    string
	color   string
	scope   string
}

struct IssueLabel {
	id int @[primary; sql: serial]
mut:
	issue_id int @[unique: 'issue_label']
	label_id int @[unique: 'issue_label']
}

// IssueAssignee stores the many-to-many relationship between issues and
// project members. The composite unique constraint makes assignment safe to
// retry without creating duplicate rows.
struct IssueAssignee {
	id         int @[primary; sql: serial]
	issue_id   int @[unique: 'issue_assignee']
	user_id    int @[unique: 'issue_assignee']
	created_at int
}

fn (mut app App) add_issue(repo_id int, author_id int, title string, text string) ! {
	app.add_issue_returning_id(repo_id, author_id, title, text)!
}

fn (mut app App) add_issue_returning_id(repo_id int, author_id int, title string, text string) !int {
	return app.add_imported_issue_returning_id(repo_id, author_id, title, text, int(time.now().unix()))!
}

fn (mut app App) add_imported_issue_returning_id(repo_id int, author_id int, title string, text string, created_at int) !int {
	return db_insert_returning_id(mut app.db, 'Issue', ['author_id', 'repo_id', 'is_pr',
		'comments_count', 'title', 'text', 'created_at', 'status', 'milestone_id', 'iteration_id',
		'time_estimate_minutes'], [
		author_id.str(),
		repo_id.str(),
		db_bool_value(false),
		'0',
		title,
		text,
		created_at.str(),
		int(IssueStatus.open).str(),
		'0',
		'0',
		'0',
	])
}

fn (mut app App) find_or_create_label(repo_id int, name string, color string) !int {
	clean_name := name.trim_space()
	clean_color := normalize_label_color(color)!
	scope, _ := parse_scoped_label(clean_name)
	if repo_id <= 0 || !valid_short_name(clean_name) {
		return error('invalid label')
	}
	existing := sql app.db {
		select from Label where repo_id == repo_id && name == clean_name limit 1
	} or { []Label{} }
	if existing.len > 0 {
		return existing[0].id
	}
	return db_insert_returning_id(mut app.db, 'Label', ['repo_id', 'name', 'color', 'scope'], [
		repo_id.str(),
		clean_name,
		clean_color,
		scope,
	])
}

fn (mut app App) add_issue_label(issue_id int, label_id int) ! {
	if issue_id <= 0 || label_id <= 0 {
		return error('invalid issue label')
	}
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}
	locked := tx.execute('update ${sql_table('Issue')} set ${sql_table('id')} = ${sql_table('id')}
		where ${sql_table('id')} = ${issue_id} returning ${sql_table('repo_id')}')!
	if locked.len != 1 {
		return error('issue not found')
	}
	issues := sql tx {
		select from Issue where id == issue_id limit 1
	}!
	labels := sql tx {
		select from Label where id == label_id limit 1
	}!
	if issues.len != 1 || labels.len != 1 || issues.first().repo_id != labels.first().repo_id {
		return error('issue and label must belong to the same repository')
	}
	if labels.first().scope != '' {
		scope := labels.first().scope
		label_repo_id := labels.first().repo_id
		repo_labels := sql tx {
			select from Label where repo_id == label_repo_id && scope == scope
		} or { []Label{} }
		for scoped_label in repo_labels {
			if scoped_label.id != label_id {
				other_id := scoped_label.id
				sql tx {
					delete from IssueLabel where issue_id == issue_id && label_id == other_id
				}!
			}
		}
	}
	existing := sql tx {
		select from IssueLabel where issue_id == issue_id && label_id == label_id limit 1
	} or { []IssueLabel{} }
	if existing.len > 0 {
		tx.commit()!
		committed = true
		return
	}
	link := IssueLabel{
		issue_id: issue_id
		label_id: label_id
	}
	sql tx {
		insert link into IssueLabel
	} or {
		if is_unique_constraint_error(err) {
			tx.rollback() or {}
			committed = true
			return
		}
		return err
	}
	tx.commit()!
	committed = true
}

fn (app &App) get_issue_labels(issue_id int) []Label {
	links := sql app.db {
		select from IssueLabel where issue_id == issue_id
	} or { []IssueLabel{} }
	mut labels := []Label{cap: links.len}
	for link in links {
		label := sql app.db {
			select from Label where id == link.label_id limit 1
		} or { []Label{} }
		if label.len > 0 {
			labels << label[0]
		}
	}
	return labels
}

fn normalize_label_color(value string) !string {
	mut clean := value.trim_space().to_lower()
	if clean.starts_with('#') {
		clean = clean[1..]
	}
	if clean.len != 6 {
		return error('label color must be a six-digit hexadecimal value')
	}
	for ch in clean {
		if !ch.is_digit() && (ch < `a` || ch > `f`) {
			return error('label color must be a six-digit hexadecimal value')
		}
	}
	return clean
}

fn (app &App) list_repo_labels(repo_id int) []Label {
	return sql app.db {
		select from Label where repo_id == repo_id order by name
	} or { []Label{} }
}

fn (app &App) find_repo_label_by_id(repo_id int, label_id int) ?Label {
	labels := sql app.db {
		select from Label where id == label_id && repo_id == repo_id limit 1
	} or { []Label{} }
	if labels.len == 0 {
		return none
	}
	return labels.first()
}

fn (mut app App) add_repo_label(repo_id int, name string, color string) !int {
	clean_name := name.trim_space()
	clean_color := normalize_label_color(color)!
	scope, _ := parse_scoped_label(clean_name)
	if repo_id <= 0 || !valid_short_name(clean_name) {
		return error('invalid label name')
	}
	existing := sql app.db {
		select from Label where repo_id == repo_id && name == clean_name limit 1
	}!
	if existing.len > 0 {
		return error('a label with that name already exists')
	}
	return db_insert_returning_id(mut app.db, 'Label', ['repo_id', 'name', 'color', 'scope'], [
		repo_id.str(),
		clean_name,
		clean_color,
		scope,
	])
}

fn (mut app App) update_repo_label(repo_id int, label_id int, name string, color string) ! {
	clean_name := name.trim_space()
	clean_color := normalize_label_color(color)!
	scope, _ := parse_scoped_label(clean_name)
	if repo_id <= 0 || label_id <= 0 || !valid_short_name(clean_name) {
		return error('invalid label')
	}
	app.find_repo_label_by_id(repo_id, label_id) or { return error('label not found') }
	duplicates := sql app.db {
		select from Label where repo_id == repo_id && name == clean_name && id != label_id limit 1
	}!
	if duplicates.len > 0 {
		return error('a label with that name already exists')
	}
	sql app.db {
		update Label set name = clean_name, color = clean_color, scope = scope where id == label_id && repo_id == repo_id
	}!
}

fn parse_scoped_label(name string) (string, string) {
	parts := name.split('::')
	if parts.len != 2 {
		return '', name.trim_space()
	}
	scope := parts[0].trim_space().to_lower()
	value := parts[1].trim_space()
	if scope == '' || value == '' {
		return '', name.trim_space()
	}
	return scope, value
}

fn (mut app App) backfill_scoped_labels() ! {
	labels := sql app.db {
		select from Label
	}!
	for label in labels {
		scope, _ := parse_scoped_label(label.name)
		if label.scope == scope {
			continue
		}
		id := label.id
		sql app.db {
			update Label set scope = scope where id == id
		}!
	}
}

fn (mut app App) remove_issue_label(issue_id int, label_id int) ! {
	if issue_id <= 0 || label_id <= 0 {
		return error('invalid issue label')
	}
	sql app.db {
		delete from IssueLabel where issue_id == issue_id && label_id == label_id
	}!
}

fn (mut app App) delete_repo_label(repo_id int, label_id int) ! {
	label := app.find_repo_label_by_id(repo_id, label_id) or { return error('label not found') }
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}
	id := label.id
	sql tx {
		delete from IssueLabel where label_id == id
	}!
	sql tx {
		delete from Label where id == id && repo_id == repo_id
	}!
	tx.commit()!
	committed = true
}

fn (mut app App) find_issue_by_id(issue_id int) ?Issue {
	issues := sql app.db {
		select from Issue where id == issue_id limit 1
	} or { []Issue{} }
	if issues.len == 0 {
		return none
	}
	mut issue := issues.first()
	app.populate_issue_assignees(mut issue)
	return issue
}

fn (mut app App) find_repo_issues_as_page(repo_id int, page int) []Issue {
	return app.find_repo_issues_as_page_by_state(repo_id, page, 'open')
}

fn (mut app App) find_repo_issues_as_page_by_state(repo_id int, page int, state string) []Issue {
	off := page * commits_per_page
	mut issues := match normalize_issue_state(state) {
		'all' {
			sql app.db {
				select from Issue where repo_id == repo_id && is_pr == false order by created_at desc limit commits_per_page offset off
			} or { []Issue{} }
		}
		'closed' {
			closed_status := IssueStatus.closed
			sql app.db {
				select from Issue where repo_id == repo_id && is_pr == false && status == closed_status order by created_at desc limit commits_per_page offset off
			} or { []Issue{} }
		}
		else {
			open_status := IssueStatus.open
			sql app.db {
				select from Issue where repo_id == repo_id && is_pr == false && status == open_status order by created_at desc limit commits_per_page offset off
			} or { []Issue{} }
		}
	}
	for mut issue in issues {
		app.populate_issue_assignees(mut issue)
	}
	return issues
}

fn normalize_issue_state(value string) string {
	return if value in ['open', 'closed', 'all'] { value } else { 'open' }
}

fn (mut app App) get_repo_issue_count(repo_id int) int {
	open_status := IssueStatus.open
	return sql app.db {
		select count from Issue where repo_id == repo_id && is_pr == false && status == open_status
	} or { 0 }
}

fn (mut app App) get_repo_all_issue_count(repo_id int) int {
	return sql app.db {
		select count from Issue where repo_id == repo_id && is_pr == false
	} or { 0 }
}

fn (mut app App) get_repo_closed_issue_count(repo_id int) int {
	closed_status := IssueStatus.closed
	return sql app.db {
		select count from Issue where repo_id == repo_id && is_pr == false && status == closed_status
	} or { 0 }
}

fn (mut app App) sync_repo_open_issue_count(repo_id int) ! {
	open_issues_count := app.get_repo_issue_count(repo_id)
	sql app.db {
		update Repo set nr_open_issues = open_issues_count where id == repo_id
	}!
}

fn placeholder_user(user_id int) User {
	username := if user_id > 0 { 'user-${user_id}' } else { 'unknown-user' }
	return User{
		id:       user_id
		username: username
		avatar:   default_avatar_name
	}
}

fn (mut app App) find_user_issues(user_id int) []Issue {
	mut issues := sql app.db {
		select from Issue where author_id == user_id && is_pr == false order by created_at desc
	} or { []Issue{} }
	for mut issue in issues {
		app.populate_issue_assignees(mut issue)
	}
	return issues
}

// find_user_assigned_issues returns only assignments which remain valid for
// the issue's project. If a user loses project access, a stale join row cannot
// expose a private issue or make the assignment appear active.
fn (mut app App) find_user_assigned_issues(user_id int) []Issue {
	if user_id <= 0 {
		return []
	}
	links := sql app.db {
		select from IssueAssignee where user_id == user_id order by created_at desc
	} or { []IssueAssignee{} }
	mut issues := []Issue{cap: links.len}
	for link in links {
		issue := app.find_issue_by_id(link.issue_id) or { continue }
		if issue.is_pr || user_id !in issue.assigned {
			continue
		}
		issues << issue
	}
	issues.sort(a.created_at > b.created_at)
	return issues
}

fn (app &App) get_issue_assignee_ids(issue_id int) []int {
	if issue_id <= 0 {
		return []
	}
	links := sql app.db {
		select from IssueAssignee where issue_id == issue_id order by created_at
	} or { []IssueAssignee{} }
	return links.map(it.user_id)
}

fn (app &App) issue_user_is_assignable(user User, repo Repo) bool {
	return user.id > 0 && user.is_registered && !user.is_blocked && app.repo_access_level(user.id, repo) >= project_access_reporter
}

fn (app &App) find_issue_assignees(issue Issue) []User {
	repo := app.find_repo_by_id(issue.repo_id) or { return [] }
	mut assignees := []User{}
	for user_id in app.get_issue_assignee_ids(issue.id) {
		user := app.get_user_by_id(user_id) or { continue }
		if app.issue_user_is_assignable(user, repo) {
			assignees << user
		}
	}
	assignees.sort(a.username.to_lower() < b.username.to_lower())
	return assignees
}

fn (app &App) populate_issue_assignees(mut issue Issue) {
	issue.assigned = app.find_issue_assignees(issue).map(it.id)
}

// find_issue_assignable_users deliberately starts from the repository owner,
// direct members, and inherited organization members. It does not search all
// registered users, so a public repository does not make arbitrary accounts
// available in the assignment control.
fn (app &App) find_issue_assignable_users(repo Repo) []User {
	mut candidate_ids := map[int]bool{}
	if repo.user_id > 0 {
		candidate_ids[repo.user_id] = true
	}
	for item in app.find_project_members(repo.id) {
		candidate_ids[item.user.id] = true
	}
	if org := app.get_org_by_name(repo.user_name) {
		for item in app.find_org_members(org.id) {
			candidate_ids[item.user.id] = true
		}
	}
	mut users := []User{cap: candidate_ids.len}
	for user_id, _ in candidate_ids {
		user := app.get_user_by_id(user_id) or { continue }
		if app.issue_user_is_assignable(user, repo) {
			users << user
		}
	}
	users.sort(a.username.to_lower() < b.username.to_lower())
	return users
}

// assign_issue is idempotent. The preflight read avoids ordinary duplicate
// writes, and the unique-constraint fallback also handles concurrent retries.
fn (mut app App) assign_issue(issue_id int, user_id int) ! {
	if issue_id <= 0 || user_id <= 0 {
		return error('invalid issue assignment')
	}
	issue := app.find_issue_by_id(issue_id) or { return error('issue not found') }
	if issue.is_pr {
		return error('pull requests cannot use issue assignments')
	}
	repo := app.find_repo_by_id(issue.repo_id) or { return error('repository not found') }
	user := app.get_user_by_id(user_id) or { return error('assignee not found') }
	if !app.issue_user_is_assignable(user, repo) {
		return error('user is not a project member')
	}
	existing := sql app.db {
		select from IssueAssignee where issue_id == issue_id && user_id == user_id limit 1
	} or { []IssueAssignee{} }
	if existing.len > 0 {
		return
	}
	assignment := IssueAssignee{
		issue_id:   issue_id
		user_id:    user_id
		created_at: int(time.now().unix())
	}
	sql app.db {
		insert assignment into IssueAssignee
	} or {
		if is_unique_constraint_error(err) {
			return
		}
		return err
	}
}

// unassign_issue is also idempotent and intentionally permits removing a
// stale assignment after a user has lost project membership.
fn (mut app App) unassign_issue(issue_id int, user_id int) ! {
	if issue_id <= 0 || user_id <= 0 {
		return error('invalid issue assignment')
	}
	issue := app.find_issue_by_id(issue_id) or { return error('issue not found') }
	if issue.is_pr {
		return error('pull requests cannot use issue assignments')
	}
	sql app.db {
		delete from IssueAssignee where issue_id == issue_id && user_id == user_id
	}!
}

fn (mut app App) find_user_mentioned_issues(username string) []Issue {
	needle := '@' + username
	mut seen := map[int]bool{}
	mut result := []Issue{}
	direct_rows := db_exec_values(mut app.db, 'select id from ${sql_table('Issue')} where is_pr is false and text like ${sql_like_pattern(needle)} order by created_at desc') or {
		[][]string{}
	}
	for row in direct_rows {
		id := row[0].int()
		if id in seen {
			continue
		}
		issue := app.find_issue_by_id(id) or { continue }
		seen[id] = true
		result << issue
	}
	comment_rows := db_exec_values(mut app.db, 'select distinct issue_id from ${sql_table('Comment')} where text like ${sql_like_pattern(needle)}') or {
		[][]string{}
	}
	for row in comment_rows {
		id := row[0].int()
		if id in seen {
			continue
		}
		issue := app.find_issue_by_id(id) or { continue }
		if issue.is_pr {
			continue
		}
		seen[id] = true
		result << issue
	}
	result.sort(a.created_at > b.created_at)
	return result
}

fn (mut app App) find_user_recent_issues(user_id int) []Issue {
	mut seen := map[int]bool{}
	mut result := []Issue{}
	authored := app.find_user_issues(user_id)
	for issue in authored {
		if issue.id in seen {
			continue
		}
		seen[issue.id] = true
		result << issue
	}
	comment_rows := db_exec_values(mut app.db, 'select distinct issue_id from ${sql_table('Comment')} where author_id = ${user_id}') or {
		[][]string{}
	}
	for row in comment_rows {
		id := row[0].int()
		if id in seen {
			continue
		}
		issue := app.find_issue_by_id(id) or { continue }
		if issue.is_pr {
			continue
		}
		seen[id] = true
		result << issue
	}
	result.sort(a.created_at > b.created_at)
	return result
}

fn (mut app App) delete_repo_issues(repo_id int) ! {
	issues := sql app.db {
		select from Issue where repo_id == repo_id
	}!
	for issue in issues {
		issue_id := issue.id
		sql app.db {
			delete from IssueAssignee where issue_id == issue_id
		}!
		sql app.db {
			delete from IssueLabel where issue_id == issue_id
		}!
		sql app.db {
			delete from Comment where issue_id == issue_id
		}!
	}
	sql app.db {
		delete from Issue where repo_id == repo_id
	}!
	sql app.db {
		delete from Label where repo_id == repo_id
	}!
}

fn (mut app App) increment_issue_comments(id int) ! {
	sql app.db {
		update Issue set comments_count = comments_count + 1 where id == id
	}!
}

fn (mut app App) set_issue_status(id int, status IssueStatus) ! {
	sql app.db {
		update Issue set status = status where id == id
	}!
}

fn (mut app App) update_issue(id int, title string, text string) ! {
	clean_title := title.trim_space()
	if id <= 0 || !valid_title(clean_title) || !valid_body(text) {
		return error('invalid issue title or description')
	}
	sql app.db {
		update Issue set title = clean_title, text = text where id == id && is_pr == false
	}!
}

fn (i &Issue) is_open() bool {
	return i.status == .open
}

fn (i &Issue) status_color() string {
	return if i.is_open() { '#1a7f37' } else { '#cf222e' }
}

fn (i &Issue) relative_time() string {
	return time.unix(i.created_at).relative()
}

fn html_escape_text(s string) string {
	return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')
}

// formatted_title renders the issue title as inline markdown so titles like
// `unknown method or field: ` + "`db.pg.Row.val`" + `` get <code> spans and
// other inline markup. The wrapping <p> tag added by the markdown converter is
// stripped so the title stays inline.
fn (i &Issue) formatted_title() veb.RawHtml {
	rendered := highlight.convert_markdown_to_html(i.title).trim_space()
	if rendered.starts_with('<p>') && rendered.ends_with('</p>') {
		return rendered[3..rendered.len - 4]
	}
	return rendered
}

// formatted_body renders the issue text as markdown.
fn (i &Issue) formatted_body() veb.RawHtml {
	return highlight.convert_markdown_to_html(i.text)
}
