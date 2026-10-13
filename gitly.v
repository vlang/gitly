// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import time
import os
import log
import api
import config
import git

const commits_per_page = 35
const default_primary_branch = 'main'
const posts_per_day = 5
const max_username_len = 40
const max_password_len = 128
const max_login_attempts = 5
const login_attempt_window_seconds = 15 * 60
const login_throttle_seconds = 15 * 60
const max_user_repos = 10
const max_repo_name_len = 100
const max_repo_description_len = 500
const max_clone_url_len = 2048
const max_title_len = 300
const max_short_name_len = 100
const max_body_len = 100_000
const max_comment_len = 50_000
const max_file_edit_size = 2 * 1024 * 1024
const max_commit_message_len = 500
const max_webhook_secret_len = 1024
const max_visit_url_len = 4096
const max_visit_referrer_len = 4096
const max_visit_ip_len = 64
const max_visit_user_agent_len = 1024
const max_namechanges = 3
const namechange_period = time.hour * 24

fn valid_title(value string) bool {
	return value.trim_space() != '' && value.len <= max_title_len
}

fn valid_short_name(value string) bool {
	return value.trim_space() != '' && value.len <= max_short_name_len
}

fn valid_body(value string) bool {
	return value.len <= max_body_len
}

fn valid_comment(value string) bool {
	return value.trim_space() != '' && value.len <= max_comment_len
}

@[heap]
pub struct App {
	veb.StaticHandler
	veb.Middleware[Context]
	started_at i64
pub mut:
	db GitlyDb
mut:
	version    string
	build_time string
	logger     log.Log
	config     config.Config
	settings   Settings
	port       int
}

pub struct Context {
	veb.Context
mut:
	user           User
	current_path   string
	page_title     string
	page_gen_time  string
	page_gen_start i64
	is_tree        bool
	show_paypal    bool
	logged_in      bool
	path_split     []string
	branch         string
	lang           Lang = .en // .ru
}

// fn C.sqlite3_config(int)
fn new_app() !&App {
	// C.sqlite3_config(3)
	conf := config.read_config('./config.json') or {
		panic('Config not found or has syntax errors')
	}

	mut app := &App{
		// db: sqlite.connect('gitly.sqlite') or { panic(err) }
		db: connect_db(conf)!
		config: conf
		started_at: time.now().unix()
	}

	set_rand_crypto_safe_seed()

	mut migration_lock := db_acquire_migration_lock(mut app.db)!
	mut migrations_committed := false
	defer {
		if !migrations_committed {
			migration_lock.rollback() or {}
		}
	}
	app.create_tables()!
	app.migrate_tables()!
	migration_lock.commit()!
	migrations_committed = true

	create_directory_if_not_exists('logs')

	app.setup_logger()

	git_result := git.Git.exec(['rev-parse', '--short', 'HEAD'])
	if git_result.exit_code == 0 && !git_result.output.contains('fatal') {
		app.version = git_result.output.trim_space()
	} else {
		app.version = 'unknown'
	}

	build_unix := os.file_last_mod_unix(os.executable())
	app.build_time = time.unix(build_unix).format()

	create_directory_if_not_exists(app.config.repo_storage_path)
	create_directory_if_not_exists(app.config.archive_path)
	create_directory_if_not_exists(app.config.avatars_path)
	if app.config.object_storage_url == '' {
		create_directory_if_not_exists(app.object_store_local_root())
	}

	app.handle_static('static', true)!
	app.serve_static('/favicon.ico', 'static/assets/favicon.svg')!
	app.mount_static_folder_at(app.config.avatars_path, '/avatars')!

	app.load_settings()

	if '-cmdapi' in os.args {
		spawn app.command_fetcher()
	}

	return app
}

fn (mut app App) setup_logger() {
	app.logger.set_level(.debug)

	app.logger.set_full_logpath('./logs/log_${time.now().ymmdd()}.log')
	app.logger.log_to_console_too()
}

pub fn (mut app App) warn(msg string) {
	app.logger.warn(msg)

	app.logger.flush()
}

pub fn (mut app App) info(msg string) {
	app.logger.info(msg)

	app.logger.flush()
}

pub fn (mut app App) debug(msg string) {
	app.logger.debug(msg)

	app.logger.flush()
}

pub fn (mut app App) init_server() {
}

pub fn (mut app App) before_request(mut ctx Context) bool {
	ctx.page_gen_start = time.ticks()
	ctx.show_paypal = is_gitly_org_host(ctx.get_header(.host) or { '' })
	ctx.set_page_title_from_path(ctx.req.url)
	ctx.set_custom_header('X-Content-Type-Options', 'nosniff') or {}
	ctx.set_custom_header('X-Frame-Options', 'DENY') or {}
	ctx.set_custom_header('Referrer-Policy', 'strict-origin-when-cross-origin') or {}
	ctx.set_custom_header('Permissions-Policy', 'camera=(), microphone=(), geolocation=()') or {}
	app.record_visit(ctx.req.url, ctx.get_header(.referer) or { '' }, ctx.ip(), ctx.user_agent()) or {
		// Traffic logging must not make the application unavailable when the
		// database is temporarily unhealthy.
		app.warn('could not record visit: ${err}')
	}
	if !request_source_is_same_origin(ctx) {
		ctx.res.set_status(.forbidden)
		ctx.text('Forbidden: cross-site state-changing request')
		return false
	}
	$if trace_prealloc ? {
		unsafe { prealloc_scope_checkpoint(c'gitly before_request start') }
	}
	ctx.logged_in = app.is_logged_in(mut ctx)
	$if trace_prealloc ? {
		unsafe { prealloc_scope_checkpoint(c'gitly checked login') }
	}
	if ctx.logged_in {
		ctx.user = app.get_user_from_cookies(ctx) or {
			ctx.logged_in = false
			User{}
		}
	}
	$if trace_prealloc ? {
		unsafe { prealloc_scope_checkpoint(c'gitly loaded user') }
	}
	lang_cookie := ctx.get_cookie('lang') or { '' }
	ctx.lang = match lang_cookie {
		'ru' { Lang.ru }
		'es' { Lang.es }
		'jp' { Lang.jp }
		'cn' { Lang.cn }
		'pt' { Lang.pt }
		else { Lang.en }
	}

	$if trace_prealloc ? {
		unsafe { prealloc_scope_checkpoint(c'gitly loaded lang') }
	}
	return true
}

// Browsers attach Origin and/or Referer to state-changing form/fetch requests.
// Reject an explicitly cross-site source before dispatching the route. Requests
// from non-browser clients commonly omit both headers and remain supported;
// bearer/HMAC authentication continues to protect those endpoints.
fn request_source_is_same_origin(ctx &Context) bool {
	if ctx.req.method !in [.post, .put, .patch, .delete] {
		return true
	}
	host := ctx.get_header(.host) or { return false }
	origin := ctx.get_header(.origin) or { '' }
	referer := ctx.get_header(.referer) or { '' }
	if origin == '' && referer == '' {
		return true
	}
	if origin != '' && !url_source_matches_host(origin, host) {
		return false
	}
	if referer != '' && !url_source_matches_host(referer, host) {
		return false
	}
	return true
}

fn url_source_matches_host(source string, request_host string) bool {
	value := source.trim_space().to_lower()
	if value == '' || value == 'null' {
		return false
	}
	for scheme in ['http://', 'https://'] {
		if !value.starts_with(scheme) {
			continue
		}
		rest := value[scheme.len..]
		source_authority := rest.all_before('/').all_before('?').all_before('#')
		return normalize_url_authority(source_authority, scheme) == normalize_url_authority(request_host.trim_space().to_lower(), scheme)
	}
	return false
}

fn normalize_url_authority(authority string, scheme string) string {
	if (scheme == 'http://' && authority.ends_with(':80')) || (scheme == 'https://' && authority.ends_with(':443')) {
		return authority.all_before_last(':')
	}
	return authority
}

// PayPal purchase links are operated only by the public Gitly instance. Use
// the request host instead of config.json so a developer's local process does
// not expose them just because the checked-in config names the production host.
fn is_gitly_org_host(request_host string) bool {
	host := request_host.trim_space().to_lower()
	return host in ['gitly.org', 'gitly.org:80', 'gitly.org:443']
}

@['/open-source']
pub fn (mut app App) open_source() veb.Result {
	return $veb.html()
}

@['/pricing']
pub fn (mut app App) pricing(mut ctx Context) veb.Result {
	return $veb.html('templates/pricing.html')
}

@['/prcing']
pub fn (mut app App) prcing(mut ctx Context) veb.Result {
	return $veb.html('templates/pricing.html')
}

@['/']
pub fn (mut app App) index(mut ctx Context) veb.Result {
	user_count := app.get_users_count_with_reconnect() or { return ctx.db_error(err) }
	if user_count == 0 {
		return ctx.redirect('/register')
	}

	return $veb.html()
}

@['/change_lang/:lang'; post]
pub fn (mut app App) change_lang(mut ctx Context, lang string) veb.Result {
	if lang !in ['en', 'ru', 'es', 'jp', 'cn', 'pt'] {
		ctx.res.set_status(.bad_request)
		return ctx.json_error('Unsupported language')
	}
	expire_date := time.now().add_days(400)
	ctx.set_cookie(name: 'lang', value: lang, path: '/', expires: expire_date)
	return ctx.json('ok')
}

pub fn (mut ctx Context) redirect_to_index() veb.Result {
	return ctx.redirect('/')
}

pub fn (mut ctx Context) redirect_to_login() veb.Result {
	return ctx.redirect('/login')
}

pub fn (mut ctx Context) redirect_to_repository(username string, repo_name string) veb.Result {
	return ctx.redirect('/${username}/${repo_name}')
}

fn (mut ctx Context) set_page_title(parts []string) {
	mut clean_parts := []string{}
	for part in parts {
		clean := part.replace('\r', ' ').replace('\n', ' ').trim_space()
		if clean != '' {
			clean_parts << clean
		}
	}
	clean_parts << 'Gitly'
	ctx.page_title = clean_parts.join(' - ')
}

fn (mut ctx Context) set_page_title_from_path(raw_url string) {
	path := raw_url.all_before('?').trim('/')
	if path == '' {
		ctx.set_page_title([]string{})
		return
	}

	segments := path.split('/')
	if segments.len >= 2 && segments[0] == 'api' {
		ctx.set_page_title([]string{})
		return
	}
	if segments.len >= 4 && segments[2] in ['issue', 'pull'] {
		ctx.set_page_title(['${page_title_label(segments[2])} #${segments[3]}',
			'${segments[0]}/${segments[1]}'])
		return
	}
	if segments.len >= 3 {
		ctx.set_page_title([page_title_label(segments[2]), '${segments[0]}/${segments[1]}'])
		return
	}
	if segments.len == 2 {
		if is_user_page_segment(segments[1]) {
			ctx.set_page_title([page_title_label(segments[1]), segments[0]])
		} else {
			ctx.set_page_title(['${segments[0]}/${segments[1]}'])
		}
		return
	}
	ctx.set_page_title([page_title_label(segments[0])])
}

fn is_user_page_segment(slug string) bool {
	return slug in ['feed', 'issues', 'pulls', 'repos', 'settings', 'stars']
}

fn page_title_label(slug string) string {
	return match slug {
		'2fa' { 'Two-factor authentication' }
		'api-tokens' { 'API tokens' }
		'blob' { 'File' }
		'branches' { 'Branches' }
		'ci' { 'CI' }
		'commit' { 'Commit' }
		'compare' { 'New pull request' }
		'contributors' { 'Contributors' }
		'discussions' { 'Discussions' }
		'edit' { 'Edit file' }
		'feed' { 'Feed' }
		'issue' { 'Issue' }
		'issues' { 'Issues' }
		'login' { 'Login' }
		'milestones' { 'Milestones' }
		'new' { 'New repository' }
		'open-source' { 'Open source' }
		'organizations' { 'Organizations' }
		'pricing' { 'Pricing' }
		'projects' { 'Projects' }
		'pull' { 'Pull request' }
		'pulls' { 'Pull requests' }
		'register' { 'Register' }
		'releases' { 'Releases' }
		'repos' { 'Repositories' }
		'search' { 'Search' }
		'security' { 'Security' }
		'settings' { 'Settings' }
		'ssh-keys' { 'SSH keys' }
		'stars' { 'Stars' }
		'tag' { 'Tag' }
		'tree' { 'Code' }
		'webhooks' { 'Webhooks' }
		else { slug.replace('-', ' ').replace('_', ' ') }
	}
}

fn (mut app App) create_tables() ! {
	sql app.db {
		create table Repo
	}!
	// unix time default now
	sql app.db {
		create table File
	}! // missing ON CONFLIC REPLACE
	// "created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Issue
	}!
	sql app.db {
		create table Label
	}!
	sql app.db {
		create table IssueLabel
	}!
	sql app.db {
		create table IssueAssignee
	}!
	// "created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Commit
	}!
	sql app.db {
		create table BranchCommit
	}!
	// author text default '' is to to avoid joins
	sql app.db {
		create table LangStat
	}!
	sql app.db {
		create table User
	}!
	sql app.db {
		create table Email
	}!
	sql app.db {
		create table Contributor
	}!
	sql app.db {
		create table Activity
	}!
	sql app.db {
		create table Visit
	}!
	sql app.db {
		create table Tag
	}!
	sql app.db {
		create table Release
	}!
	sql app.db {
		create table SshKey
	}!
	sql app.db {
		create table DeployKey
	}!
	sql app.db {
		create table Comment
	}!
	sql app.db {
		create table Branch
	}!
	sql app.db {
		create table Settings
	}!
	sql app.db {
		create table Token
	}!
	sql app.db {
		create table SecurityLog
	}!
	sql app.db {
		create table Star
	}!
	sql app.db {
		create table Watch
	}!
	sql app.db {
		create table CiStatus
	}!
	sql app.db {
		create table PullRequest
	}!
	sql app.db {
		create table PrComment
	}!
	sql app.db {
		create table PrReview
	}!
	sql app.db {
		create table PrReviewComment
	}!
	sql app.db {
		create table Webhook
	}!
	sql app.db {
		create table WebhookDelivery
	}!
	sql app.db {
		create table Discussion
	}!
	sql app.db {
		create table DiscussionComment
	}!
	sql app.db {
		create table Project
	}!
	sql app.db {
		create table ProjectColumn
	}!
	sql app.db {
		create table ProjectCard
	}!
	sql app.db {
		create table Milestone
	}!
	sql app.db {
		create table TwoFactor
	}!
	sql app.db {
		create table ApiToken
	}!
	sql app.db {
		create table Org
	}!
	sql app.db {
		create table OrgMember
	}!
	sql app.db {
		create table RepoTransfer
	}!
	sql app.db {
		create table RepoFork
	}!
	sql app.db {
		create table RepoMirror
	}!
	sql app.db {
		create table ProjectMember
	}!
	sql app.db {
		create table ProtectedBranch
	}!
	sql app.db {
		create table DeployKeyProtectedBranchGrant
	}!
	sql app.db {
		create table PrApproval
	}!
	sql app.db {
		create table DeployToken
	}!
	sql app.db {
		create table ProtectedTag
	}!
	sql app.db {
		create table Snippet
	}!
	sql app.db {
		create table LfsObject
	}!
	sql app.db {
		create table RepoLfsObject
	}!
	sql app.db {
		create table RepoHousekeeping
	}!
	sql app.db {
		create table Epic
	}!
	sql app.db {
		create table EpicIssue
	}!
	sql app.db {
		create table Iteration
	}!
	sql app.db {
		create table IssueTask
	}!
	sql app.db {
		create table IssueTimeEntry
	}!
	sql app.db {
		create table IssueRelationship
	}!
	sql app.db {
		create table ServiceDeskTicket
	}!
	sql app.db {
		create table PlatformBlob
	}!
	sql app.db {
		create table PackageArtifact
	}!
	sql app.db {
		create table PackageRetentionPolicy
	}!
	sql app.db {
		create table ContainerBlobLink
	}!
	sql app.db {
		create table ContainerManifest
	}!
	sql app.db {
		create table ContainerRetentionPolicy
	}!
	sql app.db {
		create table ContainerUpload
	}!
	sql app.db {
		create table DependencyProxyEntry
	}!
	sql app.db {
		create table SecurityScan
	}!
	sql app.db {
		create table SecurityFinding
	}!
	sql app.db {
		create table SecurityPolicy
	}!
	sql app.db {
		create table MergeApprovalPolicy
	}!
	sql app.db {
		create table ComplianceFramework
	}!
	sql app.db {
		create table RepoComplianceFramework
	}!
	sql app.db {
		create table AuditEvent
	}!
	sql app.db {
		create table ClusterAgent
	}!
	sql app.db {
		create table FeatureFlag
	}!
	sql app.db {
		create table Incident
	}!
	sql app.db {
		create table IncidentNote
	}!
	sql app.db {
		create table AlertIntegration
	}!
	sql app.db {
		create table AlertEvent
	}!
	sql app.db {
		create table TelemetryEvent
	}!
	sql app.db {
		create table OnCallSchedule
	}!
	sql app.db {
		create table OnCallRotation
	}!
	sql app.db {
		create table NamespaceQuota
	}!
	sql app.db {
		create table AbuseLimitBucket
	}!
	sql app.db {
		create table PlatformJob
	}!
	sql app.db {
		create table InstanceHeartbeat
	}!
	sql app.db {
		create table InstanceBackup
	}!
	sql app.db {
		create table DirectoryProvider
	}!
	sql app.db {
		create table ExternalIdentity
	}!
	sql app.db {
		create table ScimToken
	}!
	sql app.db {
		create table ProjectExport
	}!
	sql app.db {
		create table GroupExport
	}!
}

fn (mut app App) migrate_tables() ! {
	app.add_missing_column('User', 'github_id', 'BIGINT NOT NULL DEFAULT 0')!
	app.add_missing_column('User', 'login_attempts', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('User', 'login_attempt_window_started_at', 'BIGINT NOT NULL DEFAULT 0')!
	app.add_missing_column('User', 'login_throttled_until', 'BIGINT NOT NULL DEFAULT 0')!
	app.add_missing_column('User', 'is_bootstrap_admin', db_bool_column_type())!
	app.add_missing_column('File', 'is_size_calculated', db_bool_column_type())!
	app.add_missing_column('Settings', 'disable_tree_folder_size', db_bool_column_type())!
	app.add_missing_column('Settings', 'governance_backfilled', db_bool_column_type())!
	app.add_missing_column('Repo', 'is_deleted', db_bool_column_type())!
	app.add_missing_column('Repo', 'disable_discussions', db_bool_column_type())!
	app.add_missing_column('Repo', 'disable_projects', db_bool_column_type())!
	app.add_missing_column('Repo', 'disable_milestones', db_bool_column_type())!
	app.add_missing_column('Repo', 'disable_wiki', db_bool_column_type())!
	app.add_missing_column('Repo', 'is_pinned', db_bool_column_type())!
	app.add_missing_column('Repo', 'created_at', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Repo', 'required_approvals', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Repo', 'require_signed_commits', db_bool_column_type())!
	app.add_missing_column('Repo', 'service_desk_enabled', db_bool_column_type())!
	app.add_missing_column('Repo', 'service_desk_token_hash', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('Issue', 'status', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Release', 'created_by', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Release', 'is_manual', db_bool_column_type())!
	app.add_missing_column('Release', 'is_deleted', db_bool_column_type())!
	app.add_missing_column('Issue', 'milestone_id', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Issue', 'iteration_id', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Issue', 'time_estimate_minutes', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Label', 'scope', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('Project', 'label_id', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Project', 'milestone_id', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Project', 'iteration_id', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Project', 'assignee_id', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('ProjectColumn', 'wip_limit', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Org', 'parent_id', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Org', 'display_name', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('SshKey', 'fingerprint', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('SshKey', 'usage_type', "TEXT NOT NULL DEFAULT 'auth'")!
	app.add_missing_column('SshKey', 'expires_at', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('SshKey', 'last_used_at', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('SshKey', 'last_used_ip', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('DeployKey', 'can_push_protected', db_bool_column_type())!
	app.add_missing_column('DeployKey', 'protected_grants_migrated', db_bool_column_type())!
	app.add_missing_column('DeployKey', 'last_used_ip', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('PullRequest', 'merged_at', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('PullRequest', 'merge_commit_hash', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('PullRequest', 'head_repo_id', 'INTEGER NOT NULL DEFAULT 0')!
	// Existing approvals predate head-SHA binding. Leave them unbound so a
	// freshly-pushed head must be approved explicitly instead of silently
	// inheriting an approval for unknown code.
	app.add_missing_column('PrApproval', 'approved_head_oid', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('RepoMirror', 'encrypted_ssh_key', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('RepoMirror', 'ssh_known_hosts', "TEXT NOT NULL DEFAULT ''")!
	app.add_missing_column('RepoMirror', 'sync_started_at', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Token', 'created_at', 'INTEGER NOT NULL DEFAULT 0')!
	app.add_missing_column('Token', 'expires_at', 'INTEGER NOT NULL DEFAULT 0')!
	// Tokens created before scopes/expiry existed retain their historical full
	// access and no-expiry behavior. Every newly issued UI token supplies both
	// columns explicitly and is bounded to at most one year.
	app.add_missing_column('ApiToken', 'scopes', "TEXT NOT NULL DEFAULT 'api'")!
	app.add_missing_column('ApiToken', 'expires_at', 'INTEGER NOT NULL DEFAULT 0')!
	app.backfill_repo_created_at()!
	app.backfill_default_branch_protection_once()!
	app.clear_legacy_local_github_usernames()!
	app.backfill_ssh_key_fingerprints()!
	app.db.exec("update ${sql_table('SshKey')} set ${sql_table('usage_type')} = 'auth_and_signing' where ${sql_table('usage_type')} = 'both'")!
	app.db.exec('create unique index if not exists idx_deploy_key_protected_branch_unique on ${sql_table('DeployKeyProtectedBranchGrant')} (deploy_key_id, protected_branch_id)')!
	app.db.exec('create index if not exists idx_deploy_key_protected_branch_repo on ${sql_table('DeployKeyProtectedBranchGrant')} (repo_id, deploy_key_id)')!
	app.backfill_deploy_key_protected_branch_grants()!
	app.sync_authorized_keys() or { app.warn('Could not synchronize authorized_keys: ${err}') }

	app.db.exec('create index if not exists idx_commit_repo_created on ${sql_table('Commit')} (repo_id, created_at desc)')!
	app.db.exec('create unique index if not exists idx_repo_owner_name_active on ${sql_table('Repo')} (user_name, name) where is_deleted is false')!
	app.db.exec('create index if not exists idx_visit_created_at on ${sql_table('Visit')} (created_at desc)')!
	app.db.exec('create index if not exists idx_visit_ip_created_at on ${sql_table('Visit')} (ip, created_at desc)')!
	app.db.exec('create index if not exists idx_visit_url_created_at on ${sql_table('Visit')} (url, created_at desc)')!
	app.db.exec('create index if not exists idx_repo_fork_source on ${sql_table('RepoFork')} (source_repo_id, created_at desc)')!
	app.db.exec('create index if not exists idx_repo_fork_root on ${sql_table('RepoFork')} (root_repo_id, created_at desc)')!
	app.db.exec('create index if not exists idx_repo_mirror_due on ${sql_table('RepoMirror')} (enabled, next_update_at)')!
	app.db.exec('delete from ${sql_table('ProjectMember')} where ${sql_table('id')} not in (\n\t\tselect min(${sql_table('id')}) from ${sql_table('ProjectMember')}\n\t\tgroup by ${sql_table('repo_id')}, ${sql_table('user_id')}\n\t)')!
	app.db.exec('create unique index if not exists idx_project_member_unique on ${sql_table('ProjectMember')} (repo_id, user_id)')!
	app.db.exec('create index if not exists idx_issue_assignee_user on ${sql_table('IssueAssignee')} (user_id, issue_id)')!
	// Old imports used a read-before-insert check, which could still race. Remove
	// any duplicate links before enforcing the relationship at the database
	// layer for both upgraded and fresh installations.
	app.db.exec('delete from ${sql_table('IssueLabel')} where ${sql_table('id')} not in (\n\t\tselect min(${sql_table('id')}) from ${sql_table('IssueLabel')}\n\t\tgroup by ${sql_table('issue_id')}, ${sql_table('label_id')}\n\t)')!
	app.db.exec('create unique index if not exists idx_issue_label_unique on ${sql_table('IssueLabel')} (issue_id, label_id)')!
	app.db.exec('create index if not exists idx_api_token_hash on ${sql_table('ApiToken')} (token_hash)')!
	app.db.exec('create index if not exists idx_pr_approval_head on ${sql_table('PrApproval')} (pr_id, approved_head_oid)')!
	app.db.exec('create unique index if not exists idx_user_github_id on ${sql_table('User')} (${sql_table('github_id')}) where ${sql_table('github_id')} > 0')!
	app.db.exec('create unique index if not exists idx_user_single_bootstrap_admin on ${sql_table('User')} (${sql_table('is_bootstrap_admin')}) where ${sql_table('is_bootstrap_admin')} is true')!
	app.db.exec('create unique index if not exists idx_deploy_token_hash on ${sql_table('DeployToken')} (token_hash)')!
	app.db.exec('create unique index if not exists idx_deploy_token_username on ${sql_table('DeployToken')} (username)')!
	app.db.exec('create unique index if not exists idx_protected_tag_unique on ${sql_table('ProtectedTag')} (repo_id, pattern)')!
	app.db.exec('create unique index if not exists idx_snippet_repo_id on ${sql_table('Snippet')} (repo_id, id)')!
	app.db.exec('create unique index if not exists idx_lfs_oid on ${sql_table('LfsObject')} (oid)')!
	app.db.exec('create unique index if not exists idx_repo_lfs_object on ${sql_table('RepoLfsObject')} (repo_id, lfs_object_id)')!
	app.db.exec('create unique index if not exists idx_repo_housekeeping on ${sql_table('RepoHousekeeping')} (repo_id)')!
	app.db.exec('create index if not exists idx_org_parent on ${sql_table('Org')} (parent_id)')!
	app.db.exec('create unique index if not exists idx_epic_issue on ${sql_table('EpicIssue')} (epic_id, issue_id)')!
	app.db.exec('create index if not exists idx_iteration_org_dates on ${sql_table('Iteration')} (org_id, starts_at, due_at)')!
	app.db.exec('create index if not exists idx_issue_task_issue on ${sql_table('IssueTask')} (issue_id, position)')!
	app.db.exec('create index if not exists idx_issue_time_issue on ${sql_table('IssueTimeEntry')} (issue_id, created_at)')!
	app.db.exec('create unique index if not exists idx_issue_relationship on ${sql_table('IssueRelationship')} (source_issue_id, target_issue_id, relationship_type)')!
	app.db.exec('create unique index if not exists idx_service_desk_issue on ${sql_table('ServiceDeskTicket')} (issue_id)')!
	app.db.exec("create unique index if not exists idx_service_desk_external on ${sql_table('ServiceDeskTicket')} (repo_id, external_id) where external_id != ''")!
	app.db.exec('create unique index if not exists idx_platform_blob_oid on ${sql_table('PlatformBlob')} (oid)')!
	app.db.exec('create unique index if not exists idx_package_coordinate on ${sql_table('PackageArtifact')} (repo_id, package_type, name, version, file_name)')!
	app.db.exec('create unique index if not exists idx_package_retention_repo on ${sql_table('PackageRetentionPolicy')} (repo_id)')!
	app.db.exec('create unique index if not exists idx_container_blob_link on ${sql_table('ContainerBlobLink')} (repo_id, blob_id)')!
	app.db.exec('create unique index if not exists idx_container_manifest_ref on ${sql_table('ContainerManifest')} (repo_id, image_name, reference)')!
	app.db.exec('create unique index if not exists idx_container_retention_repo on ${sql_table('ContainerRetentionPolicy')} (repo_id)')!
	app.db.exec('create unique index if not exists idx_container_upload_uuid on ${sql_table('ContainerUpload')} (uuid)')!
	app.db.exec('create unique index if not exists idx_dependency_proxy_url on ${sql_table('DependencyProxyEntry')} (repo_id, upstream_url)')!
	app.db.exec('create index if not exists idx_security_scan_commit on ${sql_table('SecurityScan')} (repo_id, commit_sha, scan_type, id)')!
	app.db.exec('create unique index if not exists idx_security_finding_fingerprint on ${sql_table('SecurityFinding')} (repo_id, fingerprint)')!
	app.db.exec('create index if not exists idx_security_policy_repo on ${sql_table('SecurityPolicy')} (repo_id, enabled)')!
	app.db.exec('create index if not exists idx_merge_approval_policy_repo on ${sql_table('MergeApprovalPolicy')} (repo_id, enabled)')!
	app.db.exec('create unique index if not exists idx_compliance_framework_name on ${sql_table('ComplianceFramework')} (name)')!
	app.db.exec('create unique index if not exists idx_repo_compliance_framework on ${sql_table('RepoComplianceFramework')} (repo_id)')!
	app.db.exec('create index if not exists idx_audit_event_scope on ${sql_table('AuditEvent')} (scope_type, scope_id, id)')!
	app.db.exec('create unique index if not exists idx_cluster_agent_token on ${sql_table('ClusterAgent')} (token_hash)')!
	app.db.exec('create unique index if not exists idx_feature_flag_name on ${sql_table('FeatureFlag')} (repo_id, name)')!
	app.db.exec('create index if not exists idx_incident_repo_status on ${sql_table('Incident')} (repo_id, status, id)')!
	app.db.exec('create unique index if not exists idx_alert_integration_token on ${sql_table('AlertIntegration')} (token_hash)')!
	app.db.exec('create unique index if not exists idx_alert_event_fingerprint on ${sql_table('AlertEvent')} (integration_id, fingerprint)')!
	app.db.exec('create index if not exists idx_telemetry_repo_kind on ${sql_table('TelemetryEvent')} (repo_id, kind, created_at)')!
	app.db.exec('create unique index if not exists idx_on_call_rotation_user on ${sql_table('OnCallRotation')} (schedule_id, user_id)')!
	app.db.exec('create unique index if not exists idx_namespace_quota_name on ${sql_table('NamespaceQuota')} (namespace)')!
	app.db.exec('create unique index if not exists idx_abuse_limit_bucket on ${sql_table('AbuseLimitBucket')} (action, key_hash)')!
	app.db.exec('create index if not exists idx_platform_job_claim on ${sql_table('PlatformJob')} (queue, status, run_after, priority)')!
	app.db.exec('create unique index if not exists idx_instance_heartbeat_id on ${sql_table('InstanceHeartbeat')} (instance_id)')!
	app.db.exec('create unique index if not exists idx_directory_provider_name on ${sql_table('DirectoryProvider')} (name)')!
	app.db.exec('create unique index if not exists idx_external_identity_uid on ${sql_table('ExternalIdentity')} (provider_id, external_uid)')!
	app.db.exec('create unique index if not exists idx_scim_token_hash on ${sql_table('ScimToken')} (token_hash)')!
	app.db.exec('create index if not exists idx_project_export_repo on ${sql_table('ProjectExport')} (repo_id, id)')!
	app.db.exec('create index if not exists idx_group_export_org on ${sql_table('GroupExport')} (org_id, id)')!
	app.backfill_scoped_labels()!
	app.backfill_org_display_names()!
	app.backfill_bootstrap_administrator()!
}

// Existing installations have already passed bootstrap. Preserve their
// administrator choice when possible; if the historical race left an install
// with no administrator, promote its oldest registered account. This also
// makes the migration self-healing after an interrupted first registration.
fn (mut app App) backfill_bootstrap_administrator() ! {
	app.db.exec('update ${sql_table('User')} set\n\t\t${sql_table('is_admin')} = true,\n\t\t${sql_table('is_bootstrap_admin')} = true\n\t\twhere ${sql_table('id')} = (\n\t\t\tselect ${sql_table('id')} from ${sql_table('User')}\n\t\t\twhere ${sql_table('is_registered')} is true\n\t\t\torder by case when ${sql_table('is_admin')} is true then 0 else 1 end,\n\t\t\t\t${sql_table('id')} asc\n\t\t\tlimit 1\n\t\t)\n\t\tand not exists (\n\t\t\tselect 1 from ${sql_table('User')}\n\t\t\twhere ${sql_table('is_bootstrap_admin')} is true\n\t\t)')!
}

fn (mut app App) clear_legacy_local_github_usernames() ! {
	empty := ''
	sql app.db {
		update User set github_username = empty where is_github == false && github_username != empty
	}!
	github_users := sql app.db {
		select from User where is_github == true
	}!
	for github_user in github_users {
		normalized := github_user.github_username.trim_space().to_lower()
		if normalized == github_user.github_username {
			continue
		}
		id := github_user.id
		sql app.db {
			update User set github_username = normalized where id == id
		}!
	}
}

fn (mut app App) backfill_repo_created_at() ! {
	created_at := int(time.now().unix())
	app.db.exec('update ${sql_table('Repo')} set ${sql_table('created_at')} = ${created_at} where ${sql_table('created_at')} is null or ${sql_table('created_at')} <= 0')!
}

fn (mut app App) add_missing_column(table_name string, column_name string, column_type string) ! {
	if db_column_exists(mut app.db, table_name, column_name)! {
		return
	}

	app.db.exec('alter table ${sql_table(table_name)} add column ${sql_table(column_name)} ${column_type}') or {
		alter_err := err
		// A non-Gitly migrator or an older process which predates the migration
		// lock can still win after our initial check. Treat the ALTER as idempotent
		// only when an authoritative recheck confirms that exact column now exists.
		if db_column_exists(mut app.db, table_name, column_name) or { false } {
			return
		}
		return alter_err
	}
}

fn (mut ctx Context) json_success[T](result T) veb.Result {
	response := api.ApiSuccessResponse[T]{
		success: true
		result: result
	}

	return ctx.json(response)
}

fn (mut ctx Context) json_error(message string) veb.Result {
	return ctx.json(api.ApiErrorResponse{
		success: false
		message: message
	})
}

// maybe it should be implemented with another static server, in dev
fn (mut app App) send_file(filname string, content string) veb.Result {
	ctx.set_header(.content_disposition, 'attachment; filename="${filname}"')

	return ctx.ok(content)
}

fn (mut ctx Context) page_gen_time() string {
	if ctx.page_gen_start == 0 {
		return '<1ms'
	}
	diff := int(time.ticks() - ctx.page_gen_start)
	return if diff == 0 {
		'<1ms'
	} else {
		'${diff}ms'
	}
}
