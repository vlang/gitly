// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time
import git
import highlight
import validation
import config

struct Repo {
	id                 int @[primary; sql: serial]
	git_dir            string
	name               string
	user_id            int
	user_name          string
	description        string
	is_public          bool
	is_deleted         bool
	users_contributed  []string @[skip]
	users_authorized   []string @[skip]
	nr_topics          int @[skip]
	views_count        int
	latest_update_hash string @[skip]
	latest_activity    time.Time @[skip]
mut:
	clone_url               string @[skip]
	primary_branch          string
	webhook_secret          string
	tags_count              int
	nr_open_issues          int @[orm: 'open_issues_count']
	nr_open_prs             int @[orm: 'open_prs_count']
	nr_releases             int @[orm: 'releases_count']
	nr_branches             int @[orm: 'branches_count']
	nr_tags                 int
	nr_stars                int @[orm: 'stars_count']
	lang_stats              []LangStat @[skip]
	created_at              int
	nr_contributors         int
	labels                  []Label @[skip]
	status                  RepoStatus
	msg_cache               map[string]string @[skip]
	latest_commit_at        int @[skip]
	activity_buckets        []int @[skip]
	disable_discussions     bool
	disable_projects        bool
	disable_milestones      bool
	disable_wiki            bool
	is_pinned               bool
	required_approvals      int
	require_signed_commits  bool
	service_desk_enabled    bool
	service_desk_token_hash string
}

fn (r &Repo) discussions_enabled() bool {
	return !r.disable_discussions
}

fn (r &Repo) projects_enabled() bool {
	return !r.disable_projects
}

fn (r &Repo) milestones_enabled() bool {
	return !r.disable_milestones
}

fn (r &Repo) wiki_enabled() bool {
	return !r.disable_wiki
}

// log_field_separator is declared as constant in case we need to change it later
const max_free_clone_size_bytes = u64(100) * 1024 * 1024
const search_results_limit = 50
const search_candidate_limit = 250
const log_field_separator = '\x7f'
const ignored_folder = ['thirdparty']

enum RepoStatus {
	done         = 0
	caching      = 1
	clone_failed = 2
	cloning      = 3
}

enum CloneReuseResult {
	unavailable
	reused
	failed
}

enum ArchiveFormat {
	zip
	tar
	tar_gz
}

fn (f ArchiveFormat) str() string {
	return match f {
		.zip { 'zip' }
		.tar { 'tar' }
		.tar_gz { 'tar.gz' }
	}
}

fn (mut app App) save_repo(repo Repo) ! {
	id := repo.id
	desc := repo.description
	views_count := repo.views_count
	webhook_secret := repo.webhook_secret
	tags_count := repo.tags_count
	nr_tags := repo.nr_tags
	is_public := repo.is_public // if repo.is_public { 1 } else { 0 } // SQLITE hack
	open_issues_count := repo.nr_open_issues
	open_prs_count := repo.nr_open_prs
	branches_count := repo.nr_branches
	releases_count := repo.nr_releases
	stars_count := repo.nr_stars
	contributors_count := repo.nr_contributors

	// XTODO sql update all fields automatically
	// repo.update()
	sql app.db {
		update Repo set description = desc, views_count = views_count, is_public = is_public,
		webhook_secret = webhook_secret, tags_count = tags_count, nr_open_issues = open_issues_count,
		nr_open_prs = open_prs_count, nr_releases = releases_count, nr_contributors = contributors_count,
		nr_stars = stars_count, nr_branches = branches_count, nr_tags = nr_tags where id == id
	}!
}

fn (app App) find_repo_by_name_and_user_id(repo_name string, user_id int) ?Repo {
	repos := sql app.db {
		select from Repo where name == repo_name && user_id == user_id && is_deleted == false limit 1
	} or { return none }

	if repos.len == 0 {
		return none
	}

	mut repo := repos[0]
	repo.lang_stats = app.find_repo_lang_stats(repo.id)
	println('GIT DIR = ${repo.git_dir}')

	return repo
}

fn (app App) find_repo_by_name_and_username(repo_name string, username string) ?Repo {
	repos := sql app.db {
		select from Repo where name == repo_name && user_name == username && is_deleted == false limit 1
	} or { return none }
	if repos.len == 0 {
		return none
	}
	mut repo := repos.first()
	repo.lang_stats = app.find_repo_lang_stats(repo.id)
	return repo
}

fn (mut app App) get_count_user_repos(user_id int) int {
	user := app.get_user_by_id(user_id) or { return 0 }
	username := user.username
	return sql app.db {
		select count from Repo where user_id == user_id && user_name == username && is_deleted == false
	} or { 0 }
}

fn (mut app App) find_user_repos(user_id int) []Repo {
	user := app.get_user_by_id(user_id) or { return [] }
	username := user.username
	return sql app.db {
		select from Repo where user_id == user_id && user_name == username && is_deleted == false
	} or { []Repo{} }
}

fn (mut app App) find_user_public_repos(user_id int) []Repo {
	user := app.get_user_by_id(user_id) or { return [] }
	username := user.username
	return sql app.db {
		select from Repo where user_id == user_id && user_name == username && is_public == true
		&& is_deleted == false
	} or { []Repo{} }
}

const profile_repos_limit = 6

fn (mut app App) find_user_pinned_repos(user_id int, include_private bool) []Repo {
	limit := profile_repos_limit
	user := app.get_user_by_id(user_id) or { return [] }
	username := user.username
	if include_private {
		return sql app.db {
			select from Repo where user_id == user_id && user_name == username && is_pinned == true
			&& is_deleted == false limit limit
		} or { []Repo{} }
	}
	return sql app.db {
		select from Repo where user_id == user_id && user_name == username && is_pinned == true
		&& is_public == true && is_deleted == false limit limit
	} or { []Repo{} }
}

fn (mut app App) find_user_top_repos_by_stars(user_id int, include_private bool, l int) []Repo {
	user := app.get_user_by_id(user_id) or { return [] }
	username := user.username
	if include_private {
		return sql app.db {
			select from Repo where user_id == user_id && user_name == username && is_deleted == false order by nr_stars desc limit l
		} or { []Repo{} }
	}
	return sql app.db {
		select from Repo where user_id == user_id && user_name == username && is_public == true
		&& is_deleted == false order by nr_stars desc limit l
	} or { []Repo{} }
}

fn (mut app App) find_user_profile_repos(user_id int, include_private bool) []Repo {
	pinned := app.find_user_pinned_repos(user_id, include_private)
	if pinned.len > 0 {
		return pinned
	}
	return app.find_user_top_repos_by_stars(user_id, include_private, profile_repos_limit)
}

fn (mut app App) search_public_repos(query string) []Repo {
	return app.search_repos(query, 0)
}

// search_repos searches project name, namespace, and description, then applies
// the same visibility policy as direct repository access. This keeps private
// projects discoverable to their members without leaking them to anonymous or
// unrelated users.
fn (mut app App) search_repos(query string, user_id int) []Repo {
	pattern := sql_like_pattern(query)
	repo_rows := db_exec_values(mut app.db, 'select id from ${sql_table('Repo')} where is_deleted is false and (\n\t\t\tlower(name) like lower(${pattern}) or lower(user_name) like lower(${pattern}) or lower(description) like lower(${pattern})\n\t\t) order by nr_stars desc, name asc limit ${search_candidate_limit}') or {
		app.warn('Repository search failed: ${err}')
		return []
	}
	mut repos := []Repo{cap: search_results_limit}
	for row in repo_rows {
		if row.len == 0 {
			continue
		}
		repo := app.find_repo_by_id(row[0].int()) or { continue }
		if !app.user_has_repo_read_access(user_id, repo) {
			continue
		}
		repos << repo
		if repos.len == search_results_limit {
			break
		}
	}
	return repos
}

fn (app &App) find_repo_by_id(repo_id int) ?Repo {
	repos := sql app.db {
		select from Repo where id == repo_id && is_deleted == false
	} or { []Repo{} }

	if repos.len == 0 {
		return none
	}

	mut repo := repos.first()
	repo.lang_stats = app.find_repo_lang_stats(repo.id)

	return repo
}

fn normalized_non_github_clone_url(value string) string {
	mut s := value.trim_space()
	if idx := s.index('?') {
		s = s[..idx]
	}
	if idx := s.index('#') {
		s = s[..idx]
	}
	for s.ends_with('/') {
		s = s[..s.len - 1]
	}
	if s.ends_with('.git') {
		s = s[..s.len - '.git'.len]
	}
	for s.ends_with('/') {
		s = s[..s.len - 1]
	}
	lower := s.to_lower()
	for prefix in ['https://', 'http://'] {
		if lower.starts_with(prefix) {
			return s[prefix.len..]
		}
	}
	return s
}

fn same_clone_source_url(a string, b string) bool {
	if a.trim_space() == '' || b.trim_space() == '' {
		return false
	}
	if is_github_clone_url(a) && is_github_clone_url(b) {
		a_owner, a_repo := parse_github_owner_repo(a) or { return false }
		b_owner, b_repo := parse_github_owner_repo(b) or { return false }
		return a_owner.to_lower() == b_owner.to_lower() && a_repo.to_lower() == b_repo.to_lower()
	}
	return normalized_non_github_clone_url(a) == normalized_non_github_clone_url(b)
}

fn repo_origin_url(repo_dir string) ?string {
	if repo_dir == '' || !os.exists(repo_dir) || !os.is_dir(repo_dir) {
		return none
	}
	res := git.Git.exec_in_dir(repo_dir, ['config', '--get', 'remote.origin.url'])
	if res.exit_code != 0 {
		return none
	}
	origin_url := res.output.trim_space()
	if origin_url == '' {
		return none
	}
	return origin_url
}

fn (mut app App) find_reusable_clone_source(clone_url string, target_repo_id int) ?Repo {
	done_status := RepoStatus.done
	repos := sql app.db {
		select from Repo where is_deleted == false && status == done_status order by id desc
	} or { []Repo{} }

	for repo in repos {
		if repo.id == target_repo_id {
			continue
		}
		origin_url := repo_origin_url(repo.git_dir) or { continue }
		if same_clone_source_url(origin_url, clone_url) {
			return repo
		}
	}
	return none
}

fn (mut app App) increment_repo_views(repo_id int) ! {
	sql app.db {
		update Repo set views_count = views_count + 1 where id == repo_id
	}!
}

fn (mut app App) increment_repo_stars(repo_id int) ! {
	sql app.db {
		update Repo set nr_stars = nr_stars + 1 where id == repo_id
	}!
}

fn (mut app App) decrement_repo_stars(repo_id int) ! {
	sql app.db {
		update Repo set nr_stars = nr_stars - 1 where id == repo_id
	}!
}

fn (mut app App) increment_file_views(file_id int) ! {
	sql app.db {
		update File set views_count = views_count + 1 where id == file_id
	}!
}

fn (mut app App) update_repo_features(repo_id int, disable_discussions bool, disable_projects bool, disable_milestones bool, disable_wiki bool) ! {
	sql app.db {
		update Repo set disable_discussions = disable_discussions, disable_projects = disable_projects,
		disable_milestones = disable_milestones, disable_wiki = disable_wiki where id == repo_id
	}!
}

fn (mut app App) update_repo_general_settings(repo_id int, description string, is_public bool, primary_branch string) ! {
	if repo_id <= 0 || description.len > max_repo_description_len || !is_safe_ref(primary_branch) {
		return error('invalid repository settings')
	}
	sql app.db {
		update Repo set description = description, is_public = is_public, primary_branch = primary_branch
		where id == repo_id
	}!
	app.ensure_default_branch_protection(repo_id, primary_branch)!
}

fn (mut app App) set_repo_required_approvals(repo_id int, required int) ! {
	if repo_id <= 0 || required < 0 || required > 100 {
		return error('required approvals must be between 0 and 100')
	}
	sql app.db {
		update Repo set required_approvals = required where id == repo_id
	}!
}

fn (mut app App) set_repo_status(repo_id int, status RepoStatus) ! {
	sql app.db {
		update Repo set status = status where id == repo_id
	}!
}

fn (mut app App) set_repo_description(repo_id int, description string) ! {
	sql app.db {
		update Repo set description = description where id == repo_id
	}!
}

fn (mut app App) update_repo_contributor_count(repo_id int) ! {
	count := app.get_count_repo_contributors(repo_id)!
	sql app.db {
		update Repo set nr_contributors = count where id == repo_id
	}!
}

fn (mut app App) increment_repo_issues(repo_id int) ! {
	sql app.db {
		update Repo set nr_open_issues = nr_open_issues + 1 where id == repo_id
	}!
}

fn (mut app App) get_count_repo() int {
	return sql app.db {
		select count from Repo where is_deleted == false
	} or { 0 }
}

fn (mut app App) get_max_repo_id() int {
	rows := sql app.db {
		select from Repo order by id desc limit 1
	} or { return 0 }
	if rows.len == 0 {
		return 0
	}
	return rows[0].id
}

fn (mut app App) add_repo(repo Repo) ! {
	mut repo_to_insert := repo
	if repo_to_insert.created_at <= 0 {
		repo_to_insert.created_at = int(time.now().unix())
	}
	sql app.db {
		insert repo_to_insert into Repo
	}!
}

fn (r &Repo) activity_svg_points() string {
	if r.activity_buckets.len == 0 {
		return ''
	}
	mut max := 1
	for v in r.activity_buckets {
		if v > max {
			max = v
		}
	}
	width := 120.0
	height := 28.0
	step := if r.activity_buckets.len > 1 {
		width / f64(r.activity_buckets.len - 1)
	} else {
		width
	}
	mut points := []string{cap: r.activity_buckets.len}
	for i, v in r.activity_buckets {
		x := f64(i) * step
		y := height - (f64(v) / f64(max)) * (height - 2.0) - 1.0
		points << '${x:.1f},${y:.1f}'
	}
	return points.join(' ')
}

fn (r &Repo) last_updated_str() string {
	if r.latest_commit_at <= 0 {
		return ''
	}
	return time.unix(r.latest_commit_at).relative()
}

fn (r &Repo) created_str() string {
	if r.created_at <= 0 {
		return ''
	}
	return time.unix(r.created_at).relative()
}

fn (r &Repo) last_activity_str() string {
	activity_at := r.last_activity_at()
	if activity_at <= 0 {
		return ''
	}
	return time.unix(activity_at).relative()
}

fn (r &Repo) last_activity_at() int {
	return if r.latest_commit_at > 0 { r.latest_commit_at } else { r.created_at }
}

fn (mut app App) delete_repository(id int, path string, name string) ! {
	if id <= 0 {
		return error('invalid repository')
	}
	repo_id := id
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}
	// Lock and revalidate the active repository before deleting related state.
	// Without one transaction, a failure halfway through left a still-visible
	// repository with transfers, mirrors, permissions, or branch rules missing.
	locked := tx.execute('update ${sql_table('Repo')} set ${sql_table('id')} = ${sql_table('id')}\n\t\twhere ${sql_table('id')} = ${repo_id}\n\t\tand ${sql_table('is_deleted')} is false\n\t\treturning ${sql_table('id')}')!
	if locked.len != 1 {
		return error('repository is no longer available')
	}
	locked_repos := sql tx {
		select from Repo where id == repo_id && is_deleted == false limit 1
	}!
	if locked_repos.len != 1 || locked_repos[0].git_dir != path || locked_repos[0].name != name {
		// The repository may have been transferred after the route loaded it.
		// Never tombstone that new owner's row and then remove the stale path.
		return error('repository changed while deletion was requested')
	}
	locked_repo := locked_repos[0]
	container_uploads := sql tx {
		select from ContainerUpload where repo_id == repo_id
	}!
	sql tx {
		delete from RepoTransfer where repo_id == repo_id
	}!
	fork_rows := sql tx {
		select from RepoFork where repo_id == repo_id limit 1
	}!
	if fork_rows.len == 1 && fork_rows[0].source_repo_id > 0 {
		upstream_repo_id := fork_rows[0].source_repo_id
		// A fork of this fork can continue synchronizing from the nearest
		// surviving ancestor after the intermediate repository is removed.
		sql tx {
			update RepoFork set source_repo_id = upstream_repo_id where source_repo_id == repo_id
		}!
	}
	sql tx {
		// Preserve descendant lineage when an upstream repository is removed.
		// Their source id may become unavailable for synchronization, but keeping
		// the edge and root id retains the fork network and existing cross-fork
		// merge-request identity.
		delete from RepoFork where repo_id == repo_id
	}!
	sql tx {
		delete from RepoMirror where repo_id == repo_id
	}!
	sql tx {
		delete from ProjectMember where repo_id == repo_id
	}!
	sql tx {
		delete from DeployKey where repo_id == repo_id
	}!
	sql tx {
		delete from DeployToken where repo_id == repo_id
	}!
	sql tx {
		delete from ProtectedTag where repo_id == repo_id
	}!
	sql tx {
		delete from Snippet where repo_id == repo_id
	}!
	sql tx {
		delete from RepoLfsObject where repo_id == repo_id
	}!
	sql tx {
		delete from RepoHousekeeping where repo_id == repo_id
	}!
	sql tx {
		delete from ServiceDeskTicket where repo_id == repo_id
	}!
	sql tx {
		delete from PackageArtifact where repo_id == repo_id
	}!
	sql tx {
		delete from PackageRetentionPolicy where repo_id == repo_id
	}!
	sql tx {
		delete from ContainerBlobLink where repo_id == repo_id
	}!
	sql tx {
		delete from ContainerManifest where repo_id == repo_id
	}!
	sql tx {
		delete from ContainerRetentionPolicy where repo_id == repo_id
	}!
	sql tx {
		delete from ContainerUpload where repo_id == repo_id
	}!
	sql tx {
		delete from DependencyProxyEntry where repo_id == repo_id
	}!
	sql tx {
		delete from SecurityFinding where repo_id == repo_id
	}!
	sql tx {
		delete from SecurityScan where repo_id == repo_id
	}!
	sql tx {
		delete from SecurityPolicy where repo_id == repo_id
	}!
	sql tx {
		delete from MergeApprovalPolicy where repo_id == repo_id
	}!
	sql tx {
		delete from RepoComplianceFramework where repo_id == repo_id
	}!
	sql tx {
		delete from ClusterAgent where repo_id == repo_id
	}!
	sql tx {
		delete from FeatureFlag where repo_id == repo_id
	}!
	incidents := sql tx {
		select from Incident where repo_id == repo_id
	}!
	for incident in incidents {
		incident_id := incident.id
		sql tx {
			delete from IncidentNote where incident_id == incident_id
		}!
	}
	sql tx {
		delete from Incident where repo_id == repo_id
	}!
	integrations := sql tx {
		select from AlertIntegration where repo_id == repo_id
	}!
	for integration in integrations {
		integration_id := integration.id
		sql tx {
			delete from AlertEvent where integration_id == integration_id
		}!
	}
	sql tx {
		delete from AlertIntegration where repo_id == repo_id
	}!
	sql tx {
		delete from TelemetryEvent where repo_id == repo_id
	}!
	schedules := sql tx {
		select from OnCallSchedule where repo_id == repo_id
	}!
	for schedule in schedules {
		schedule_id := schedule.id
		sql tx {
			delete from OnCallRotation where schedule_id == schedule_id
		}!
	}
	sql tx {
		delete from OnCallSchedule where repo_id == repo_id
	}!
	sql tx {
		delete from ProjectExport where repo_id == repo_id
	}!
	sql tx {
		delete from ProtectedBranch where repo_id == repo_id
	}!
	sql tx {
		delete from DeployKeyProtectedBranchGrant where repo_id == repo_id
	}!
	sql tx {
		update Repo set is_deleted = true where id == repo_id
	}!
	tombstoned := sql tx {
		select count from Repo where id == repo_id && is_deleted == true
	}!
	if tombstoned != 1 {
		return error('repository could not be tombstoned')
	}
	tx.commit()!
	committed = true
	app.info('Marked repo as deleted (${repo_id}, ${locked_repo.name})')

	// Authorized-keys generation and filesystem removal are side effects, so run
	// them only after the database cleanup is durably committed.
	app.sync_authorized_keys() or { app.warn('Could not update authorized_keys: ${err}') }
	for upload in container_uploads {
		app.object_store_delete(upload.storage_key) or {
			app.warn('Could not remove abandoned container upload ${upload.uuid}: ${err}')
		}
	}
	app.delete_repo_folder(locked_repo.git_dir)
	app.info('Removed repo folder (${repo_id}, ${locked_repo.name})')
}

fn (mut app App) user_has_repo(user_id int, repo_name string) bool {
	user := app.get_user_by_id(user_id) or { return false }
	username := user.username
	count := sql app.db {
		select count from Repo where user_id == user_id && user_name == username && name == repo_name
		&& is_deleted == false
	} or { 0 }
	return count > 0
}

fn (mut app App) update_repo_from_fs(mut repo Repo, recompute_lang_stats bool) ! {
	println('UPDATE REPO FROM FS')
	repo_id := repo.id

	// This refresh rebuilds derived cache tables through helpers that currently
	// accept App rather than orm.Tx. Never bracket those pooled DB calls with raw
	// BEGIN/COMMIT: PostgreSQL may serve each call on a different connection and
	// leave the BEGIN connection checked in with an open transaction. Each step
	// is therefore deliberately idempotent and auto-committed for now.

	// Language analysis reads every file in the repo and is slow on large
	// repos; callers on the git push hot path pass `false` and run it in a
	// background thread instead, so the git client is not blocked.
	if recompute_lang_stats {
		repo.analyze_lang(app)!
	}

	app.info(repo.nr_contributors.str())
	app.fetch_branches(repo)!
	app.fetch_tags(repo)!

	branches_output := repo.git('branch -a')
	println('b output=${branches_output}')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.update_repo_branch_from_fs(mut repo, branch_name)!
	}

	repo.nr_contributors = app.get_count_repo_contributors(repo_id)!
	repo.nr_branches = app.get_count_repo_branches(repo_id)
	repo.nr_open_prs = app.get_repo_open_pr_count(repo_id)

	for tag in app.get_all_repo_tags(repo_id) {
		app.add_release(tag.id, repo_id, time.unix(tag.created_at), tag.message)!
	}
	repo.nr_releases = app.get_repo_release_count(repo_id)
	repo.nr_tags = app.get_all_repo_tags(repo_id).len
	repo.tags_count = repo.nr_tags

	app.save_repo(repo)!
	app.info('Repo updated')
}

// fn (mut app App) update_repo_branch_from_fs(mut ctx Context, mut repo Repo, branch_name string) ! {
fn (mut app App) update_repo_branch_from_fs(mut repo Repo, branch_name string) ! {
	app.update_repo_branch_data(mut repo, branch_name)!
}

fn (mut app App) update_repo_from_remote(mut repo Repo) ! {
	repo_id := repo.id

	repo.git('fetch --all')
	repo.git('pull --all')

	repo.analyze_lang(app)!

	app.info(repo.nr_contributors.str())
	app.fetch_branches(repo)!
	app.fetch_tags(repo)!

	branches_output := repo.git('branch -a')

	for branch_output in branches_output.split_into_lines() {
		branch_name := git.parse_git_branch_output(branch_output)

		app.update_repo_branch_from_fs(mut repo, branch_name)!
	}

	for tag in app.get_all_repo_tags(repo_id) {
		app.add_release(tag.id, repo_id, time.unix(tag.created_at), tag.message)!
	}
	repo.nr_releases = app.get_repo_release_count(repo_id)
	repo.nr_tags = app.get_all_repo_tags(repo_id).len
	repo.tags_count = repo.nr_tags

	repo.nr_contributors = app.get_count_repo_contributors(repo_id)!
	repo.nr_branches = app.get_count_repo_branches(repo_id)
	repo.nr_open_prs = app.get_repo_open_pr_count(repo_id)

	app.save_repo(repo)!
	app.info('Repo updated')
}

fn (mut app App) update_repo_branch_data(mut repo Repo, branch_name string) ! {
	repo_id := repo.id
	branch := app.find_repo_branch_by_name(repo.id, branch_name)

	if branch.id == 0 {
		return
	}

	// Resolve reachability independently from metadata parsing. Only prune after
	// Git has successfully produced the complete current history.
	reachable_result := git.Git.exec_in_dir(repo.git_dir, ['rev-list', branch_name])
	if reachable_result.exit_code != 0 {
		return error('could not list branch commits: ${reachable_result.output}')
	}
	mut reachable := map[string]bool{}
	for raw_hash in reachable_result.output.split_into_lines() {
		commit_hash := raw_hash.trim_space()
		if commit_hash != '' {
			reachable[commit_hash] = true
		}
	}
	log_format := '%H${log_field_separator}%aE${log_field_separator}%cD${log_field_separator}%s${log_field_separator}%aN'
	log_result := git.Git.exec_in_dir(repo.git_dir, ['--no-pager', 'log', branch_name,
		'--pretty=${log_format}'])
	if log_result.exit_code != 0 {
		return error('could not read branch history: ${log_result.output}')
	}
	data := log_result.output

	for line in data.split_into_lines() {
		args := line.split(log_field_separator)

		if args.len > 4 {
			commit_hash := args[0]
			commit_author_email := args[1]
			commit_message := args[3]
			commit_author := args[4]
			mut commit_author_id := 0

			// A merged history is not linear: an already-indexed first parent can
			// appear before unseen commits from the merged side branch.
			if app.commit_exists(repo_id, branch.id, commit_hash) {
				continue
			}

			commit_date := time.parse_rfc2822(args[2]) or {
				app.info('Error: ${err}')
				return
			}

			user := app.get_user_by_email(commit_author_email) or { User{} }

			if user.id > 0 {
				app.add_contributor(user.id, repo_id)!

				commit_author_id = user.id
			}

			app.add_commit(repo_id, branch.id, commit_hash, commit_author, commit_author_id, commit_message, int(commit_date.unix()))!
		}
	}
	app.prune_branch_commit_links(repo_id, branch.id, reachable)!
}

fn (mut app App) update_repo_branch_after_change(repo_id int, branch_name string) ! {
	if branch_name == '' {
		return
	}

	mut repo := app.find_repo_by_id(repo_id) or { return }

	app.fetch_branch(repo, branch_name)!
	app.update_repo_branch_data(mut repo, branch_name)!
	repo.nr_contributors = app.get_count_repo_contributors(repo_id)!
	repo.nr_branches = app.get_count_repo_branches(repo_id)
	repo.nr_open_prs = app.get_repo_open_pr_count(repo_id)
	app.save_repo(repo)!
}

// TODO: tags and other stuff
// update_repo_after_push runs on the request thread after a git push so that
// new commits appear in the UI immediately. It skips language analysis,
// which is slow and runs in bg_recompute_lang_stats instead.
fn (mut app App) update_repo_after_push(repo_id int, branch_name string) ! {
	mut repo := app.find_repo_by_id(repo_id) or { return }

	app.update_repo_from_fs(mut repo, false)!
	app.delete_repository_files_in_branch(repo_id, branch_name)!
	app.clear_open_pr_approvals_for_head(repo_id, branch_name)!
	app.refresh_open_cross_fork_pr_heads(repo_id, branch_name)
}

fn (mut app App) update_repo_after_ref_changes(repo_id int, updates []git.GitRefUpdate) ! {
	mut repo := app.find_repo_by_id(repo_id) or { return }
	app.update_repo_from_fs(mut repo, false)!
	mut seen := map[string]bool{}
	for update in updates {
		branch := update.branch_name() or { continue }
		if seen[branch] {
			continue
		}
		seen[branch] = true
		app.delete_repository_files_in_branch(repo_id, branch)!
		app.clear_open_pr_approvals_for_head(repo_id, branch)!
		app.refresh_open_cross_fork_pr_heads(repo_id, branch)
		if update.is_delete() {
			app.delete_repo_branch_by_name(repo_id, branch)!
		}
	}
	app.sync_repo_branch_count(repo_id)!
}

// bg_recompute_lang_stats recomputes language statistics for a repo in a
// background thread. It opens its own sqlite connection (matching the
// clone_repo / bg_fetch_files_info pattern) because the shared App.db
// handle is not safe for concurrent use across threads.
fn bg_recompute_lang_stats(repo_id int, conf config.Config) {
	mut app := &App{
		db: connect_db(conf) or {
			eprintln('bg_recompute_lang_stats: cannot open ${db_backend_name()} db: ${err}')
			return
		}
		config: conf
	}
	app.load_settings()
	defer {
		app.db.close() or {}
	}

	repo := app.find_repo_by_id(repo_id) or {
		eprintln('bg_recompute_lang_stats: repo ${repo_id} not found')
		return
	}
	repo.analyze_lang(app) or {
		eprintln('bg_recompute_lang_stats: analyze_lang failed for repo ${repo_id}: ${err}')
	}
}

fn (r &Repo) analyze_lang(app &App) ! {
	file_paths := r.get_all_file_paths()

	mut all_size := 0
	mut lang_stats := map[string]int{}
	mut langs := map[string]highlight.Lang{}

	for file_path in file_paths {
		lang := highlight.extension_to_lang(file_path.split('.').last()) or { continue }
		file_content := r.read_file(r.primary_branch, file_path)
		lines := file_content.split_into_lines()
		size := calc_lines_of_code(lines, lang)

		if lang.name !in lang_stats {
			lang_stats[lang.name] = 0
		}
		if lang.name !in langs {
			langs[lang.name] = lang
		}

		lang_stats[lang.name] = lang_stats[lang.name] + size
		all_size += size
	}

	mut d_lang_stats := []LangStat{}
	mut tmp_a := []int{}

	for lang, amount in lang_stats {
		// skip 0 lines of code
		if amount == 0 {
			continue
		}

		mut tmp := f32(amount) / f32(all_size)
		tmp *= 1000
		pct := int(tmp)
		if pct !in tmp_a {
			tmp_a << pct
		}
		lang_data := langs[lang]
		d_lang_stats << LangStat{
			repo_id: r.id
			name: lang_data.name
			pct: pct
			color: lang_data.color
			lines_count: amount
		}
	}

	tmp_a.sort()
	tmp_a = tmp_a.reverse()

	mut tmp_stats := []LangStat{}

	for pct in tmp_a {
		all_with_ptc := r.lang_stats.filter(it.pct == pct)
		for lang in all_with_ptc {
			tmp_stats << lang
		}
	}

	app.remove_repo_lang_stats(r.id)!

	for lang_stat in d_lang_stats {
		app.add_lang_stat(lang_stat)!
	}
}

fn calc_lines_of_code(lines []string, lang highlight.Lang) int {
	mut size := 0
	lcomment := lang.line_comments
	mut mlcomment_start := ''
	mut mlcomment_end := ''
	if lang.mline_comments.len >= 2 {
		mlcomment_start = lang.mline_comments[0]
		mlcomment_end = lang.mline_comments[1]
	}
	mut in_comment := false
	for line in lines {
		tmp_line := line.trim_space()
		if tmp_line.len > 0 { // Empty line ignored
			if tmp_line.contains(mlcomment_start) {
				in_comment = true
				if tmp_line.starts_with(mlcomment_start) {
					continue
				}
			}
			if tmp_line.contains(mlcomment_end) {
				if in_comment {
					in_comment = false
				}
				if tmp_line.ends_with(mlcomment_end) {
					continue
				}
			}
			if in_comment {
				continue
			}
			if tmp_line.contains(lcomment) {
				if tmp_line.starts_with(lcomment) {
					continue
				}
			}
			size++
		}
	}
	return size
}

fn (r &Repo) get_all_file_paths() []string {
	ls_output := r.git('ls-tree -r ${r.primary_branch} --name-only')
	mut file_paths := []string{}

	for file_path in ls_output.split_into_lines() {
		path_parts := file_path.split('/')
		has_ignored_folders := path_parts.any(ignored_folder.contains(it))

		if has_ignored_folders {
			continue
		}

		file_paths << file_path
	}

	return file_paths
}

// TODO: return ?string
// git runs `git -C <git_dir> <words...>` with an argument vector, never through
// a shell, so `&` and `;` are not shell metacharacters here and the guard below
// is not a security control. It is kept only because it is cheap.
//
// The residual risk is argument injection, not command injection: a ref name
// that begins with `-` can still be read by git as an option. Callers that
// interpolate a caller-supplied ref (see `pr_routes.v`, `repo/branch.v`) should
// pass it after a `--` separator, or move to `Git.exec_in_dir_with_env` with an
// argument array. `split_command` also splits on whitespace, so a ref
// containing a space is broken into several arguments.
fn (r &Repo) git(command string) string {
	if command.contains('&') || command.contains(';') {
		return ''
	}

	command_with_path := '-C ${r.git_dir} ${command}'

	command_result := git.Git.exec_in_dir_command(r.git_dir, command)
	command_exit_code := command_result.exit_code
	if command_exit_code != 0 {
		println('git error ${command_with_path} with ${command_exit_code} exit code out=${command_result.output}')

		return ''
	}

	return command_result.output.trim_space()
}

fn (r &Repo) parse_ls(ls_line string, branch string) ?File {
	tab_pos := ls_line.index('\t') or { return none }
	metadata := ls_line[..tab_pos].fields()
	if metadata.len < 4 {
		return none
	}

	item_type := metadata[1]
	item_size := metadata[3]
	item_path := ls_line[tab_pos + 1..]

	item_name := os.base(item_path)
	if item_name == '' {
		return none
	}

	parent_path := os.dir(item_path)

	if item_name.contains('"\\') {
		// Unqoute octal UTF-8 strings
	}

	return File{
		name: item_name
		parent_path: parent_path
		repo_id: r.id
		branch: branch
		is_dir: item_type == 'tree'
		size: if item_type == 'blob' { item_size.int() } else { 0 }
		is_size_calculated: item_type == 'blob'
	}
}

fn (r &Repo) parse_top_file_line(line string, branch string) ?File {
	tab_pos := line.index('\t') or { return none }
	meta := line[..tab_pos]
	item_path := line[tab_pos + 1..]
	meta_parts := meta.fields()
	if meta_parts.len < 4 || meta_parts[1] != 'blob' {
		return none
	}

	lower_path := item_path.to_lower()
	for segment in lower_path.split('/') {
		if segment == 'thirdparty' || segment == '3rdparty' || segment == 'third_party' || segment == 'third-party' {
			return none
		}
	}

	excluded_extensions := ['.png', '.jpg', '.jpeg', '.obj', '.json', '.pdf']
	for ext in excluded_extensions {
		if lower_path.ends_with(ext) {
			return none
		}
	}

	item_name := os.base(item_path)
	if item_name == '' {
		return none
	}

	parent_path_raw := os.dir(item_path)
	parent_path := if parent_path_raw == '.' { '' } else { parent_path_raw }

	return File{
		name: item_name
		parent_path: parent_path
		repo_id: r.id
		branch: branch
		is_dir: false
		size: meta_parts[3].int()
		is_size_calculated: true
	}
}

fn (r &Repo) lookup_file_via_git(branch string, path string) ?File {
	git_result := git.Git.exec_in_dir(r.git_dir, ['ls-tree', '--full-name', '--long', branch, '--',
		path])
	if git_result.exit_code != 0 {
		return none
	}
	for line in git_result.output.split_into_lines() {
		tab_pos := line.index('\t') or { continue }
		meta := line[..tab_pos]
		item_path := line[tab_pos + 1..]
		meta_parts := meta.fields()
		if meta_parts.len < 4 || meta_parts[1] != 'blob' {
			continue
		}
		item_name := os.base(item_path)
		if item_name == '' {
			continue
		}
		parent_path_raw := os.dir(item_path)
		parent_path := if parent_path_raw == '.' { '' } else { parent_path_raw }
		return File{
			name: item_name
			parent_path: parent_path
			repo_id: r.id
			branch: branch
			is_dir: false
			size: meta_parts[3].int()
			is_size_calculated: true
		}
	}
	return none
}

fn (r &Repo) top_files(branch string, limit int) []File {
	git_result := git.Git.exec_in_dir(r.git_dir, ['ls-tree', '-r', '--full-name', '--long', branch])
	if git_result.exit_code != 0 {
		eprintln('git ls-tree top files error: ${git_result.output}')
		return []File{}
	}

	mut files := []File{}
	for line in git_result.output.split_into_lines() {
		file := r.parse_top_file_line(line, branch) or { continue }
		files << file
	}

	files.sort(b.size < a.size)
	if files.len > limit {
		return files[..limit]
	}

	return files
}

// Fetches all files via `git ls-tree` and saves them in db
fn (mut app App) cache_repository_items(mut r Repo, branch string, path string) ![]File {
	if r.status == .caching {
		app.info('`${r.name}` is being cached already')
		return []
	}

	if path == '.' {
		r.status = .caching

		defer {
			r.status = .done
		}
	}
	normalized_path := normalize_tree_path(path)
	mut tree_args := ['ls-tree', '--full-name',
		'--format=%(objectmode) %(objecttype) %(objectname) %(objectsize)%x09%(path)', branch]
	if normalized_path != '' {
		tree_args << '--'
		tree_args << '${normalized_path}/'
	}
	tree_result := git.Git.exec_in_dir(r.git_dir, tree_args)
	if tree_result.exit_code != 0 {
		return error('could not list repository tree: ${tree_result.output}')
	}
	repository_ls := tree_result.output

	// mode type name path
	item_info_lines := repository_ls.split('\n')

	mut dirs := []File{} // dirs first
	mut files := []File{}

	for item_info in item_info_lines {
		is_item_info_empty := validation.is_string_empty(item_info)

		if is_item_info_empty {
			continue
		}

		file := r.parse_ls(item_info, branch) or {
			app.warn('failed to parse ${item_info}')
			continue
		}

		if file.is_dir {
			dirs << file
		} else {
			files << file
		}
	}

	dirs << files
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}
	for file in dirs {
		sql tx {
			insert file into File
		}!
	}
	tx.commit()!
	committed = true

	return dirs
}

// fetches last message and last time for each file
// this is slow, so it's run in the background thread
fn (mut app App) slow_fetch_files_info(mut repo Repo, branch string, path string) ! {
	files := app.find_repository_items(repo.id, branch, path)

	for i in 0 .. files.len {
		if files[i].last_msg != '' {
			app.warn('skipping ${files[i].name}')
			continue
		}

		app.fetch_file_info(repo, files[i])!
	}
}

fn (mut app App) slow_fetch_folder_sizes(mut repo Repo, branch string, path string) ! {
	files := app.find_repository_items(repo.id, branch, path)
	dirs := files.filter(it.is_dir && !it.is_size_calculated)
	if dirs.len == 0 {
		return
	}

	dir_names := dirs.map(it.name)
	sizes := repo.calculate_child_folder_sizes(branch, path, dir_names)

	for dir in dirs {
		size := sizes[dir.name] or { 0 }
		app.update_file_size(dir.id, size, true)!
	}
}

fn (r &Repo) calculate_child_folder_sizes(branch string, path string, dir_names []string) map[string]int {
	mut sizes := map[string]int{}
	for dir_name in dir_names {
		sizes[dir_name] = 0
	}
	if dir_names.len == 0 {
		return sizes
	}

	normalized_path := normalize_tree_path(path)
	mut args := ['ls-tree', '-r', '--full-name', '--long', branch]
	if normalized_path != '' {
		args << '--'
		args << normalized_path
	}

	result := git.Git.exec_in_dir(r.git_dir, args)
	if result.exit_code != 0 {
		eprintln('git ls-tree error while calculating folder sizes: ${result.output}')
		return sizes
	}

	prefix := if normalized_path == '' { '' } else { '${normalized_path}/' }
	for line in result.output.split_into_lines() {
		tab_pos := line.index('\t') or { continue }
		meta := line[..tab_pos]
		item_path := line[tab_pos + 1..]
		meta_parts := meta.fields()
		if meta_parts.len < 4 || meta_parts[1] != 'blob' {
			continue
		}

		mut relative_path := item_path
		if prefix != '' {
			if !item_path.starts_with(prefix) {
				continue
			}
			relative_path = item_path[prefix.len..]
		}

		slash_pos := relative_path.index('/') or { continue }
		child_dir := relative_path[..slash_pos]
		if child_dir !in sizes {
			continue
		}

		sizes[child_dir] = sizes[child_dir] + meta_parts[3].int()
	}

	return sizes
}

fn normalize_tree_path(path string) string {
	return path.trim_string_left('/').trim_string_right('/')
}

fn (r Repo) get_last_branch_commit_hash(branch_name string) string {
	git_result := git.Git.exec_in_dir(r.git_dir, ['log', '-n', '1', branch_name, '--pretty=format:%H'])
	git_output := git_result.output

	if git_result.exit_code != 0 {
		eprintln('git log error: ${git_output}')
	}

	return git_output.trim_space()
}

fn (r Repo) git_advertise(service string) string {
	git_result := git.Git.exec([service, '--stateless-rpc', '--advertise-refs', r.git_dir])
	git_output := git_result.output

	if git_result.exit_code != 0 {
		eprintln('git ${service} error: ${git_output}')
	}

	return git_output
}

fn (r Repo) archive_tag(tag string, path string, format ArchiveFormat) ! {
	if !is_safe_ref(tag) {
		return error('invalid tag name')
	}
	result := git.Git.exec_in_dir(r.git_dir, ['archive', 'refs/tags/${tag}', '--format=${format}',
		'--output=${path}'])
	if result.exit_code != 0 {
		return error('git archive failed: ${result.output}')
	}
}

fn (r Repo) get_commit_patch(commit_hash string) ?string {
	if !is_valid_commit_hash(commit_hash) {
		return none
	}
	result := git.Git.exec_in_dir(r.git_dir, ['format-patch', '--stdout', '-1', commit_hash])
	if result.exit_code != 0 || result.output == '' {
		return none
	}
	return result.output
}

fn (r Repo) git_smart(service string, input string) string {
	return r.git_smart_with_env(service, input, map[string]string{})
}

// drain_process_output consumes both output pipes while the child is running.
// Git hooks can write enough data to stderr to fill its pipe; draining stdout
// first in that situation deadlocks because Git cannot exit and close stdout.
fn drain_process_output(mut process os.Process) (string, string) {
	mut output := ''
	mut errors := ''
	for process.is_alive() {
		mut drained := false
		for process.is_pending(.stdout) {
			chunk := process.stdout_read()
			if chunk.len == 0 {
				break
			}
			output += chunk
			drained = true
		}
		for process.is_pending(.stderr) {
			chunk := process.stderr_read()
			if chunk.len == 0 {
				break
			}
			errors += chunk
			drained = true
		}
		if !drained {
			time.sleep(time.millisecond)
		}
	}
	// Capture bytes written between the final liveness check and process exit.
	output += process.stdout_slurp()
	errors += process.stderr_slurp()
	return output, errors
}

fn (r Repo) git_smart_with_env(service string, input string, extra_env map[string]string) string {
	git_path := git.get_git_executable_path() or { 'git' }
	real_repository_path := os.real_path(r.git_dir)

	mut process := os.new_process(git_path)
	process.set_args([service, '--stateless-rpc', real_repository_path])
	if extra_env.len > 0 {
		mut environment := os.environ()
		for key, value in extra_env {
			environment[key] = value
		}
		process.set_environment(environment)
	}

	process.set_redirect_stdio()
	process.run()
	process.stdin_write(input)
	process.stdin_write('\n')

	output, errors := drain_process_output(mut process)
	process.wait()
	exit_code := process.code
	process.close()

	if exit_code != 0 {
		diagnostic := if errors.len > 4096 { errors[..4096] + '\n[truncated]' } else { errors }
		eprintln('git ${service} failed (${exit_code}): ${diagnostic}')
		return ''
	}
	if errors.len > 0 {
		diagnostic := if errors.len > 4096 { errors[..4096] + '\n[truncated]' } else { errors }
		eprintln('git ${service} warning: ${diagnostic}')
	}

	return output
}

fn (mut app App) generate_clone_url(repo Repo) string {
	hostname := app.config.hostname
	username := repo.user_name
	repo_name := repo.name

	return 'https://${hostname}/${username}/${repo_name}.git'
}

fn (app &App) generate_ssh_clone_url(repo Repo) string {
	hostname := if app.config.ssh_hostname.trim_space() != '' {
		app.config.ssh_hostname.trim_space()
	} else {
		app.config.hostname.trim_space()
	}
	port := if app.config.ssh_port > 0 { app.config.ssh_port } else { 22 }
	user := if app.config.ssh_user.trim_space() != '' {
		app.config.ssh_user.trim_space()
	} else {
		'git'
	}
	return if port == 22 {
		'${user}@${hostname}:${repo.user_name}/${repo.name}.git'
	} else {
		'ssh://${user}@${hostname}:${port}/${repo.user_name}/${repo.name}.git'
	}
}

fn first_line(s string) string {
	pos := s.index('\n') or { return s }
	return s[..pos]
}

fn (mut app App) fetch_file_info(r &Repo, file &File) ! {
	result := git.Git.exec_in_dir(r.git_dir, ['log', '-n1', '--format=%B___%at___%H___%an',
		file.branch, '--', file.full_path()])
	if result.exit_code != 0 {
		return error('could not fetch file history: ${result.output}')
	}
	logs := result.output.trim_space()
	vals := logs.split('___')
	if vals.len < 3 {
		return
	}
	last_msg := first_line(vals[0])
	last_time := vals[1].int()
	last_hash := vals[2]

	file_id := file.id
	sql app.db {
		update File set last_msg = last_msg, last_time = last_time, last_hash = last_hash
		where id == file_id
	}!
}

fn (mut app App) update_file_size(file_id int, size int, is_size_calculated bool) ! {
	sql app.db {
		update File set size = size, is_size_calculated = is_size_calculated where id == file_id
	}!
}

fn (mut app App) update_repo_primary_branch(repo_id int, branch string) ! {
	sql app.db {
		update Repo set primary_branch = branch where id == repo_id
	}!
	app.ensure_default_branch_protection(repo_id, branch)!
}

fn (r &Repo) clone_progress_path() string {
	return r.git_dir + '.progress'
}

fn directory_size(path string) u64 {
	if !os.exists(path) {
		return 0
	}
	if !os.is_dir(path) {
		return os.file_size(path)
	}
	mut total := u64(0)
	for entry in os.ls(path) or { return total } {
		total += directory_size(os.join_path(path, entry))
	}
	return total
}

fn mark_clone_size_limit(progress_path string) {
	mut log := os.open_append(progress_path) or {
		os.write_file(progress_path, '${git.clone_size_limit_marker}\n') or {}
		return
	}
	log.write_string('\n${git.clone_size_limit_marker}\n') or {}
	log.close()
}

fn cleanup_oversized_clone(repo_path string) {
	os.rmdir_all(repo_path) or { eprintln('failed to remove oversized clone ${repo_path}: ${err}') }
}

fn append_clone_progress(progress_path string, message string) {
	mut log := os.open_append(progress_path) or {
		os.write_file(progress_path, '${message}\n') or {}
		return
	}
	log.write_string('${message}\n') or {}
	log.close()
}

fn git_result_ok(res os.Result) bool {
	return res.exit_code == 0 && !res.output.to_lower().contains('fatal')
}

fn remote_default_branch(repo_dir string) ?string {
	res := git.Git.exec_in_dir(repo_dir, ['ls-remote', '--symref', 'origin', 'HEAD'])
	if !git_result_ok(res) {
		return none
	}
	for line in res.output.split_into_lines() {
		if !line.starts_with('ref: refs/heads/') || !line.ends_with('\tHEAD') {
			continue
		}
		branch := line['ref: refs/heads/'.len..line.len - '\tHEAD'.len].trim_space()
		if branch != '' {
			return branch
		}
	}
	return none
}

fn local_head_branch(repo_dir string) ?string {
	res := git.Git.exec_in_dir(repo_dir, ['symbolic-ref', '--quiet', '--short', 'HEAD'])
	if !git_result_ok(res) {
		return none
	}
	branch := res.output.trim_space()
	if branch == '' {
		return none
	}
	return branch
}

fn repo_has_branch(repo_dir string, branch string) bool {
	if branch == '' {
		return false
	}
	res := git.Git.exec_in_dir(repo_dir, ['show-ref', '--verify', '--quiet', 'refs/heads/${branch}'])
	return res.exit_code == 0
}

fn detect_primary_branch(repo_dir string, fallback string) string {
	for branch in [remote_default_branch(repo_dir) or { '' }, local_head_branch(repo_dir) or { '' },
		fallback, 'main', 'master'] {
		if repo_has_branch(repo_dir, branch) {
			return branch
		}
	}
	return fallback
}

fn point_head_to_branch(repo_dir string, branch string) bool {
	if branch == '' {
		return false
	}
	res := git.Git.exec_in_dir(repo_dir, ['symbolic-ref', 'HEAD', 'refs/heads/${branch}'])
	return git_result_ok(res)
}

fn (mut r Repo) clone_from_existing(source Repo, enforce_size_limit bool) CloneReuseResult {
	if source.git_dir == '' || source.git_dir == r.git_dir || !os.exists(source.git_dir) || !os.is_dir(source.git_dir) || os.exists(r.git_dir) {
		return .unavailable
	}
	progress_path := r.clone_progress_path()
	os.rm(progress_path) or {}
	append_clone_progress(progress_path, 'Reusing existing local clone from ${source.user_name}/${source.name}')
	tmp_path := '${r.git_dir}.tmp-${os.getpid()}-${time.ticks()}'
	os.rmdir_all(tmp_path) or {}
	// Go through upload-pack instead of copying the bare directory byte-for-byte.
	// A raw copy also carries repository-local config, remotes, hooks, hidden refs,
	// and unreachable objects (for example refs used for merge request previews).
	// Besides leaking state between projects that share an upstream URL, copying a
	// live object directory can race a concurrent repack. `--no-local` asks Git to
	// transfer only the advertised heads/tags and their reachable objects into a
	// freshly initialized bare repository.
	local_clone := git.Git.exec(['clone', '--bare', '--no-local', source.git_dir, tmp_path])
	if !git_result_ok(local_clone) {
		append_clone_progress(progress_path, 'Local clone reuse failed while copying; falling back to git clone.')
		os.rmdir_all(tmp_path) or {}
		eprintln('failed to clone reusable repo ${source.git_dir} to ${tmp_path}: ${local_clone.output}')
		return .unavailable
	}
	os.mv(tmp_path, r.git_dir, overwrite: false) or {
		append_clone_progress(progress_path, 'Local clone reuse failed while installing copy; falling back to git clone.')
		os.rmdir_all(tmp_path) or {}
		eprintln('failed to move reusable repo ${tmp_path} to ${r.git_dir}: ${err}')
		return .unavailable
	}
	set_url_result := git.Git.exec_in_dir(r.git_dir, ['remote', 'set-url', 'origin', r.clone_url])
	if !git_result_ok(set_url_result) {
		add_origin_result := git.Git.exec_in_dir(r.git_dir, ['remote', 'add', 'origin', r.clone_url])
		if !git_result_ok(add_origin_result) {
			append_clone_progress(progress_path, 'Local clone reuse failed while resetting origin; falling back to git clone.')
			os.rmdir_all(r.git_dir) or {}
			eprintln('failed to set origin for reused repo ${r.git_dir}: ${set_url_result.output}${add_origin_result.output}')
			return .unavailable
		}
	}
	append_clone_progress(progress_path, 'Fetching latest updates from origin')
	fetch_result := git.Git.exec_in_dir(r.git_dir, ['fetch', '--prune', 'origin',
		'+refs/heads/*:refs/heads/*', '+refs/tags/*:refs/tags/*'])
	if !git_result_ok(fetch_result) {
		append_clone_progress(progress_path, 'Local clone reuse failed while fetching updates; falling back to git clone.')
		os.rmdir_all(r.git_dir) or {}
		eprintln('failed to fetch reused repo ${r.git_dir}: ${fetch_result.output}')
		return .unavailable
	}
	r.primary_branch = detect_primary_branch(r.git_dir, r.primary_branch)
	point_head_to_branch(r.git_dir, r.primary_branch)
	if enforce_size_limit && directory_size(r.git_dir) >= max_free_clone_size_bytes {
		r.status = .clone_failed
		mark_clone_size_limit(progress_path)
		cleanup_oversized_clone(r.git_dir)
		println('reused git clone removed because repo is larger than 100 MB')
		return .failed
	}
	r.status = .done
	os.rm(progress_path) or {}
	eprintln('clone reused from ${source.git_dir}')
	return .reused
}

fn (mut r Repo) clone(enforce_size_limit bool) {
	eprintln('R CLONE')
	progress_path := r.clone_progress_path()
	max_clone_size_bytes := if enforce_size_limit { max_free_clone_size_bytes } else { u64(0) }
	clone_result := git.Git.clone_with_progress_limit(r.clone_url, r.git_dir, progress_path, max_clone_size_bytes)
	clone_exit_code := clone_result.exit_code

	if enforce_size_limit && clone_exit_code == git.clone_size_limit_exit_code {
		r.status = .clone_failed
		mark_clone_size_limit(progress_path)
		cleanup_oversized_clone(r.git_dir)
		println('git clone stopped because repo is larger than 100 MB')
		return
	}

	if clone_exit_code != 0 {
		r.status = .clone_failed
		println('git clone failed with exit code ${clone_exit_code}')
		return
	}

	if enforce_size_limit && directory_size(r.git_dir) >= max_free_clone_size_bytes {
		r.status = .clone_failed
		mark_clone_size_limit(progress_path)
		cleanup_oversized_clone(r.git_dir)
		println('git clone removed because repo is larger than 100 MB')
		return
	}

	r.primary_branch = detect_primary_branch(r.git_dir, r.primary_branch)
	point_head_to_branch(r.git_dir, r.primary_branch)
	r.status = .done
	// progress file is no longer needed after a successful clone
	os.rm(progress_path) or {}
	eprintln('clone done')
}

fn (r &Repo) read_file(branch string, path string) string {
	valid_path := path.trim_string_left('/')

	println('read_file() path=${valid_path}')
	t := time.now()

	// s := r.git('--no-pager show ${branch}:${valid_path}')
	s := git.Git.show_file_blob(r.git_dir, branch, valid_path) or { '' }
	println(time.since(t))
	println(':)')
	return s
}

fn find_readme_file(items []File) ?File {
	files := items.filter(it.name.to_lower().starts_with('readme.') && it.name.split('.').len == 2 && !it.is_dir)

	if files.len == 0 {
		return none
	}

	// firstly search markdown files
	readme_md_files := files.filter(it.name.to_lower().ends_with('.md'))

	if readme_md_files.len > 0 {
		return readme_md_files.first()
	}

	// and then txt files
	readme_txt_files := files.filter(it.name.to_lower().ends_with('.txt'))

	if readme_txt_files.len > 0 {
		return readme_txt_files.first()
	}

	return none
}

fn find_license_file(items []File) ?File {
	// List of common license file names
	license_common_files := ['license', 'license.md', 'license.txt', 'licence', 'licence.md',
		'licence.txt']

	files := items.filter(license_common_files.contains(it.name.to_lower()))

	if files.len == 0 {
		return none
	}
	return files[0]
}

// can_read_repo reports whether the current request may read the given,
// already-loaded repo's contents (tree/blob/raw/contributors/...). Public
// repos are readable by anyone, including anonymous visitors; private repos
// are readable only by their owner. Call this on every repo-scoped read route
// before running a git command or returning repo data.
fn (app &App) can_read_repo(ctx Context, repo Repo) bool {
	if repo.is_public {
		return true
	}
	return ctx.logged_in && app.user_has_repo_read_access(ctx.user.id, repo)
}

fn (app &App) has_user_repo_read_access(ctx Context, user_id int, repo_id int) bool {
	if !ctx.logged_in {
		return false
	}
	repo := app.find_repo_by_id(repo_id) or { return false }
	return app.user_has_repo_read_access(user_id, repo)
}

fn (app &App) user_has_repo_read_access(user_id int, repo Repo) bool {
	if repo.is_public {
		return true
	}
	return app.repo_access_level(user_id, repo) >= project_access_reporter
}

fn (app &App) has_user_repo_read_access_by_repo_name(ctx Context, user_id int, repo_owner_name string, repo_name string) bool {
	repo := app.find_repo_by_name_and_username(repo_name, repo_owner_name) or { return false }
	return app.has_user_repo_read_access(ctx, user_id, repo.id)
}

fn (app &App) user_can_write_repo(user_id int, repo Repo) bool {
	return app.repo_access_level(user_id, repo) >= project_access_developer
}

// can_admin_repo reports whether the currently logged-in user is allowed to
// maintain the given, already-loaded target repo (settings, webhooks, branch
// rules, and similar routine administration). It must be called with the repo
// loaded from the URL owner, not re-queried by the logged-in user's name —
// otherwise a user could pass the check for someone else's repo simply by
// owning a repo with the same name.
fn (app &App) can_admin_repo(ctx Context, repo Repo) bool {
	return ctx.logged_in && app.repo_access_level(ctx.user.id, repo) >= project_access_maintainer
}

// can_own_repo is the narrower gate for operations that surrender or destroy
// repository ownership. A Maintainer can administer a project, but only a
// personal namespace owner or organization administrator has Owner access.
fn (app &App) can_own_repo(ctx Context, repo Repo) bool {
	return ctx.logged_in && app.repo_access_level(ctx.user.id, repo) >= project_access_owner
}
