// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import os
import time
import git
import rand

struct RepoFork {
	id              int @[primary; sql: serial]
	repo_id         int @[unique]
	source_repo_id  int
	root_repo_id    int
	created_by      int
	created_at      int
	last_sync_at    int
	last_sync_error string
}

struct ForkSyncResult {
mut:
	updated []string
	skipped []string
}

fn (app &App) find_fork_by_repo(repo_id int) ?RepoFork {
	rows := sql app.db {
		select from RepoFork where repo_id == repo_id limit 1
	} or { []RepoFork{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

// find_repo_forks returns the other repositories in the complete fork network,
// not just immediate children. A fork of a fork is still a sibling of the
// original forks for discovery and cross-fork contribution purposes.
fn (app &App) find_repo_forks(repo_id int) []Repo {
	root_repo_id := app.repo_fork_root_id(repo_id)
	relations := sql app.db {
		select from RepoFork where root_repo_id == root_repo_id order by created_at desc
	} or { []RepoFork{} }
	mut repos := []Repo{cap: relations.len + 1}
	if root_repo_id != repo_id {
		root := app.find_repo_by_id(root_repo_id) or { Repo{} }
		if root.id > 0 && !root.is_deleted {
			repos << root
		}
	}
	for relation in relations {
		if relation.repo_id == repo_id {
			continue
		}
		repo := app.find_repo_by_id(relation.repo_id) or { continue }
		if !repo.is_deleted {
			repos << repo
		}
	}
	return repos
}

fn (app &App) count_repo_forks(repo_id int) int {
	root_repo_id := app.repo_fork_root_id(repo_id)
	current_repo_id := repo_id
	mut count := sql app.db {
		select count from RepoFork where root_repo_id == root_repo_id && repo_id != current_repo_id
	} or { 0 }
	if root_repo_id != repo_id {
		root := app.find_repo_by_id(root_repo_id) or { Repo{} }
		if root.id > 0 && !root.is_deleted {
			count++
		}
	}
	return count
}

fn (app &App) repo_fork_root_id(repo_id int) int {
	relation := app.find_fork_by_repo(repo_id) or { return repo_id }
	return if relation.root_repo_id > 0 { relation.root_repo_id } else { relation.source_repo_id }
}

fn (app &App) repos_share_fork_network(first_id int, second_id int) bool {
	return first_id > 0 && second_id > 0
		&& app.repo_fork_root_id(first_id) == app.repo_fork_root_id(second_id)
}

fn (app &App) namespace_has_fork_in_network(repo_id int, owner_name string) bool {
	if repo_id <= 0 || owner_name == '' {
		return false
	}
	root_repo_id := app.repo_fork_root_id(repo_id)
	root := app.find_repo_by_id(root_repo_id) or { Repo{} }
	if root.id > 0 && root.user_name == owner_name && !root.is_deleted {
		return true
	}
	relations := sql app.db {
		select from RepoFork where root_repo_id == root_repo_id
	} or { []RepoFork{} }
	for relation in relations {
		repo := app.find_repo_by_id(relation.repo_id) or { continue }
		if !repo.is_deleted && repo.user_name == owner_name {
			return true
		}
	}
	return false
}

fn fetch_fork_branch_into(target Repo, source Repo, branch string, destination_ref string) ! {
	if !is_safe_ref(branch) || !destination_ref.starts_with('refs/')
		|| destination_ref.contains_any('\x00\r\n ') || destination_ref.contains('..') {
		return error('Invalid fork branch')
	}
	branch_exists := git.Git.exec_in_dir(source.git_dir, ['show-ref', '--verify', '--quiet',
		'refs/heads/${branch}'])
	if branch_exists.exit_code != 0 {
		return error('The source branch no longer exists')
	}
	fetch := git.Git.exec_in_dir(target.git_dir, ['fetch', '--no-tags', source.git_dir,
		'+refs/heads/${branch}:${destination_ref}'])
	if fetch.exit_code != 0 {
		return error('Could not fetch the fork branch')
	}
}

fn (mut app App) refresh_cross_fork_pr_head(target Repo, pr PullRequest) ! {
	if pr.head_repo_id <= 0 || pr.head_repo_id == target.id {
		return
	}
	if !app.repos_share_fork_network(target.id, pr.head_repo_id) {
		return error('The merge request source is outside this fork network')
	}
	source := app.find_repo_by_id(pr.head_repo_id) or {
		return error('The source fork no longer exists')
	}
	candidate_ref := 'refs/gitly-fetches/${pr.id}/${rand.ulid()}'
	defer {
		git.Git.exec_in_dir(target.git_dir, ['update-ref', '-d', candidate_ref])
	}
	// Fetch into an isolated ref first. Approval state is invalidated before the
	// public merge-request ref advances, so a transient database error can never
	// leave a new revision paired with approvals for the old one.
	fetch_fork_branch_into(target, source, pr.head_branch, candidate_ref)!
	new_head := git_rev_parse(target.git_dir, candidate_ref)!
	old_head := git_rev_parse(target.git_dir, pr.head_ref()) or { '' }
	if old_head == new_head {
		return
	}
	app.clear_pull_request_approvals(pr.id)!
	expected_old := if old_head == '' { zero_oid_like(new_head)! } else { old_head }
	update_git_ref_expected(target.git_dir, pr.head_ref(), new_head, expected_old)!
}

// Refresh cross-fork merge-request refs when the source branch changes. Page
// views remain read-only, while pushes and web edits publish the new candidate
// and invalidate approvals as part of the repository update workflow.
fn (mut app App) refresh_open_cross_fork_pr_heads(source_repo_id int, branch string) {
	if source_repo_id <= 0 || !is_safe_ref(branch) {
		return
	}
	wanted := int(PrStatus.open)
	prs := sql app.db {
		select from PullRequest where head_repo_id == source_repo_id && head_branch == branch
		&& status == wanted
	} or { []PullRequest{} }
	for pr in prs {
		target := app.find_repo_by_id(pr.repo_id) or { continue }
		app.refresh_cross_fork_pr_head(target, pr) or {
			app.warn('Could not refresh merge request ${pr.id} after ${branch} changed: ${err}')
		}
	}
}

fn (mut app App) delete_repo_fork_relationships(repo_id int) ! {
	relation := app.find_fork_by_repo(repo_id) or { RepoFork{} }
	if relation.source_repo_id > 0 {
		upstream_repo_id := relation.source_repo_id
		sql app.db {
			update RepoFork set source_repo_id = upstream_repo_id where source_repo_id == repo_id
		}!
	}
	sql app.db {
		delete from RepoFork where repo_id == repo_id
	}!
}

fn configure_fork_remote(path string, source Repo) ! {
	set_existing := git.Git.exec_in_dir(path, ['remote', 'set-url', 'upstream', source.git_dir])
	if set_existing.exit_code != 0 {
		rename := git.Git.exec_in_dir(path, ['remote', 'rename', 'origin', 'upstream'])
		if rename.exit_code != 0 {
			add := git.Git.exec_in_dir(path, ['remote', 'add', 'upstream', source.git_dir])
			if add.exit_code != 0 {
				return error('Could not configure the fork upstream')
			}
		}
	}
	set_url := git.Git.exec_in_dir(path, ['remote', 'set-url', 'upstream', source.git_dir])
	if set_url.exit_code != 0 {
		return error('Could not configure the fork upstream')
	}
	fetch_config := git.Git.exec_in_dir(path, ['config', 'remote.upstream.fetch',
		'+refs/heads/*:refs/remotes/upstream/*'])
	if fetch_config.exit_code != 0 {
		return error('Could not configure upstream branch tracking')
	}
}

fn (mut app App) create_fork(source Repo, owner_name string, owner_user_id int, name string,
	description string, is_public bool, default_branch_only bool, created_by int) !Repo {
	if source.id <= 0 || source.status != .done || source.is_deleted || owner_name == ''
		|| owner_user_id <= 0 || created_by <= 0 {
		return error('The source repository is not available for forking')
	}
	if app.namespace_has_fork_in_network(source.id, owner_name) {
		return error('The destination namespace already contains a repository in this fork network')
	}
	app.ensure_namespace_repository_quota(owner_name)!
	owner_dir := os.join_path(app.config.repo_storage_path, owner_name)
	os.mkdir_all(owner_dir)!
	target_path := os.join_path(owner_dir, name)
	if os.exists(target_path) {
		return error('The destination repository already exists')
	}
	mut clone_args := ['clone', '--bare', '--no-hardlinks']
	if default_branch_only {
		clone_args << '--single-branch'
		clone_args << '--branch'
		clone_args << source.primary_branch
	}
	clone_args << source.git_dir
	clone_args << target_path
	clone_result := git.Git.exec(clone_args)
	if clone_result.exit_code != 0 {
		os.rmdir_all(target_path) or {}
		return error('Could not copy the source repository: ${clone_result.output.trim_space()}')
	}
	configure_fork_remote(target_path, source) or {
		os.rmdir_all(target_path) or {}
		return err
	}
	mut row := Repo{
		git_dir:             target_path
		name:                name
		user_id:             owner_user_id
		user_name:           owner_name
		description:         description
		is_public:           is_public && source.is_public
		primary_branch:      source.primary_branch
		created_at:          int(time.now().unix())
		status:              .done
		disable_discussions: source.disable_discussions
		disable_projects:    source.disable_projects
		disable_milestones:  source.disable_milestones
	}
	app.add_repo(row) or {
		os.rmdir_all(target_path) or {}
		return err
	}
	created := app.find_repo_by_name_and_username(name, owner_name) or {
		os.rmdir_all(target_path) or {}
		return error('Could not load the newly created fork')
	}
	source_relation := app.find_fork_by_repo(source.id) or { RepoFork{} }
	relation := RepoFork{
		repo_id:        created.id
		source_repo_id: source.id
		root_repo_id:   if source_relation.root_repo_id > 0 {
			source_relation.root_repo_id
		} else {
			source.id
		}
		created_by:     created_by
		created_at:     int(time.now().unix())
	}
	sql app.db {
		insert relation into RepoFork
	} or {
		id := created.id
		sql app.db {
			update Repo set is_deleted = true where id == id
		} or {}
		os.rmdir_all(target_path) or {}
		return err
	}
	app.update_repo_primary_branch(created.id, source.primary_branch) or {}
	row = created
	app.update_repo_from_fs(mut row, false) or {
		app.warn('Could not warm fork repository cache: ${err}')
	}
	return created
}

fn (mut app App) sync_fork(repo Repo, relation RepoFork, default_branch_only bool) !ForkSyncResult {
	if relation.repo_id != repo.id {
		return error('Invalid fork relationship')
	}
	source := app.find_repo_by_id(relation.source_repo_id) or {
		app.record_fork_sync(relation.id, 'The upstream repository no longer exists')
		return error('The upstream repository no longer exists')
	}
	configure_fork_remote(repo.git_dir, source) or {
		app.record_fork_sync(relation.id, err.str())
		return err
	}
	fetch := git.Git.exec_in_dir(repo.git_dir, ['fetch', '--prune', '--no-tags', 'upstream',
		'+refs/heads/*:refs/remotes/upstream/*'])
	if fetch.exit_code != 0 {
		app.record_fork_sync(relation.id, fetch.output.trim_space())
		return error('Could not fetch upstream: ${fetch.output.trim_space()}')
	}
	refs := git.Git.exec_in_dir(repo.git_dir, ['for-each-ref', '--format=%(refname:strip=3)',
		'refs/remotes/upstream'])
	if refs.exit_code != 0 {
		app.record_fork_sync(relation.id, refs.output.trim_space())
		return error('Could not inspect upstream branches')
	}
	mut result := ForkSyncResult{}
	for raw_branch in refs.output.split_into_lines() {
		branch := raw_branch.trim_space()
		if branch == '' || (default_branch_only && branch != source.primary_branch) {
			continue
		}
		local_ref := 'refs/heads/${branch}'
		remote_ref := 'refs/remotes/upstream/${branch}'
		remote_sha := git_rev_parse(repo.git_dir, remote_ref) or {
			result.skipped << branch
			continue
		}
		local_exists := git.Git.exec_in_dir(repo.git_dir, ['show-ref', '--verify', '--quiet',
			local_ref]).exit_code == 0
		mut expected_old_sha := zero_oid_like(remote_sha) or {
			result.skipped << branch
			continue
		}
		if local_exists {
			expected_old_sha = git_rev_parse(repo.git_dir, local_ref) or {
				result.skipped << branch
				continue
			}
			ff := git.Git.exec_in_dir(repo.git_dir, ['merge-base', '--is-ancestor', expected_old_sha,
				remote_sha])
			if ff.exit_code != 0 {
				result.skipped << branch
				continue
			}
		}
		app.verify_commit_range_for_policy(repo, expected_old_sha, remote_sha) or {
			result.skipped << branch
			continue
		}
		update_git_ref_expected(repo.git_dir, local_ref, remote_sha, expected_old_sha) or {
			result.skipped << branch
			continue
		}
		result.updated << branch
	}
	mut refreshed := repo
	app.update_repo_from_fs(mut refreshed, false) or {
		message := 'Branches synchronized, but the repository cache could not be refreshed'
		app.record_fork_sync(relation.id, message)
		return error(message)
	}
	app.record_fork_sync(relation.id, '')
	return result
}

fn (mut app App) record_fork_sync(id int, message string) {
	now := int(time.now().unix())
	sql app.db {
		update RepoFork set last_sync_at = now, last_sync_error = message where id == id
	} or {}
}
