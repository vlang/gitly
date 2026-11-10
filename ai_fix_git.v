// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import git
import os
import rand

struct AiFixPatch {
	tree_oid string
	patch    string
}

fn ai_fix_git(repo Repo, args []string, env map[string]string, hooks_dir string) os.Result {
	mut options := ['-c', 'core.hooksPath=${hooks_dir}', '-c', 'core.fsmonitor=false']
	options << args
	return git.Git.exec_in_dir_with_env(repo.git_dir, options, env)
}

fn ai_fix_safe_path(path string) bool {
	if !is_valid_repo_file_path(path) || path.contains_any('\\:') {
		return false
	}
	for part in path.split('/') {
		name := part.to_lower().trim_right(' .')
		if name in ['.git', 'git~1'] {
			return false
		}
	}
	return true
}

fn ai_fix_validate_changes(raw string, numstat string) ! {
	entries := raw.split('\x00')
	if entries.len < 3 || entries.last() != '' || entries.len % 2 != 1
		|| entries.len > 41 {
		return error('The fix must change between 1 and 20 regular text files')
	}
	for i := 0; i < entries.len - 1; i += 2 {
		meta := entries[i].fields()
		if meta.len != 5 || !meta[0].starts_with(':') || !ai_fix_safe_path(entries[i + 1]) {
			return error('The patch contains an unsupported file path or change')
		}
		old_mode := meta[0][1..]
		new_mode := meta[1]
		valid := match meta[4] {
			'A' { old_mode == '000000' && new_mode in ['100644', '100755'] }
			'D' { old_mode in ['100644', '100755'] && new_mode == '000000' }
			'M' { old_mode in ['100644', '100755'] && new_mode == old_mode }
			else { false }
		}
		if !valid {
			return error('AI fixes cannot change symlinks, submodules or file modes')
		}
	}
	for line in numstat.split('\x00') {
		if line == '' {
			continue
		}
		stats := line.split('\t')
		if stats.len != 3 || stats[0] == '-' || stats[1] == '-' {
			return error('AI fixes cannot change binary files')
		}
	}
}

// Apply exclusively to a private index. No checkout, model-supplied command,
// repository hook, clean/smudge filter or textconv process is executed.
fn prepare_ai_fix_patch(repo Repo, expected_head string, patch string) !AiFixPatch {
	if !is_full_commit_oid(expected_head) || patch.len == 0 || patch.len > 128 * 1024
		|| patch.contains('\x00') || !patch.starts_with('diff --git ')
		|| patch.contains('\nGIT binary patch\n') {
		return error('The AI response must contain a nonempty text patch of at most 128 KiB')
	}
	tmp_dir := os.join_path(os.temp_dir(), 'gitly_ai_${rand.ulid()}')
	os.mkdir(tmp_dir, mode: 0o700) or { return error('Could not prepare the patch workspace') }
	defer {
		os.rmdir_all(tmp_dir) or {}
	}
	patch_path := os.join_path(tmp_dir, 'fix.patch')
	os.write_file(patch_path, patch) or { return error('Could not prepare the patch') }
	env := {
		'GIT_INDEX_FILE': os.join_path(tmp_dir, 'index')
	}
	if ai_fix_git(repo, ['read-tree', expected_head], env, tmp_dir).exit_code != 0 {
		return error('The source commit is unavailable')
	}
	for check in [true, false] {
		mut args := ['apply', '--cached', '--whitespace=nowarn']
		if check {
			args << '--check'
		}
		args << ['--', patch_path]
		if ai_fix_git(repo, args, env, tmp_dir).exit_code != 0 {
			return error('The patch does not apply cleanly to the reviewed source commit')
		}
	}
	raw := ai_fix_git(repo, ['diff', '--cached', '--raw', '--no-abbrev', '--no-renames', '-z',
		expected_head, '--'], env, tmp_dir)
	numstat := ai_fix_git(repo, ['diff', '--cached', '--numstat', '--no-ext-diff', '--no-textconv',
		'--no-renames', '-z', expected_head, '--'], env, tmp_dir)
	if raw.exit_code != 0 || numstat.exit_code != 0 {
		return error('Could not inspect the proposed changes')
	}
	ai_fix_validate_changes(raw.output, numstat.output)!
	diff := ai_fix_git(repo, ['diff', '--cached', '--no-ext-diff', '--no-textconv', '--no-color',
		'--no-renames', '--src-prefix=a/', '--dst-prefix=b/', expected_head, '--'], env, tmp_dir)
	if diff.exit_code != 0 || diff.output.len == 0 || diff.output.len > 128 * 1024 {
		return error('The resulting patch is empty or too large')
	}
	tree := ai_fix_git(repo, ['write-tree'], env, tmp_dir)
	if tree.exit_code != 0 || !is_full_commit_oid(tree.output.trim_space()) {
		return error('Could not prepare the fixed source tree')
	}
	return AiFixPatch{ tree_oid: tree.output.trim_space(), patch: diff.output }
}

fn commit_ai_fix_patch(repo Repo, branch string, expected_head string, patch string, author string) !string {
	if !is_safe_ref(branch) || !is_full_commit_oid(expected_head) {
		return error('Invalid source branch or commit')
	}
	current := git_rev_parse(repo.git_dir, 'refs/heads/${branch}') or { '' }
	if current != expected_head {
		return error('The source branch changed. Generate a new fix for its latest commit')
	}
	prepared := prepare_ai_fix_patch(repo, expected_head, patch)!
	tmp_dir := os.join_path(os.temp_dir(), 'gitly_ai_commit_${rand.ulid()}')
	os.mkdir(tmp_dir, mode: 0o700) or { return error('Could not prepare the commit workspace') }
	defer {
		os.rmdir_all(tmp_dir) or {}
	}
	env := {
		'GIT_AUTHOR_NAME':     author
		'GIT_AUTHOR_EMAIL':    '${author}@gitly'
		'GIT_COMMITTER_NAME':  author
		'GIT_COMMITTER_EMAIL': '${author}@gitly'
	}
	created := ai_fix_git(repo, ['commit-tree', prepared.tree_oid, '-p', expected_head, '-m',
		'Fix failed CI with Gitly AI'], env, tmp_dir)
	commit := created.output.trim_space()
	if created.exit_code != 0 || !is_full_commit_oid(commit) {
		return error('Could not create the fix commit')
	}
	published := ai_fix_git(repo, ['update-ref', 'refs/heads/${branch}', commit, expected_head],
		env, tmp_dir)
	if published.exit_code != 0 {
		return error('The source branch changed before the fix could be committed')
	}
	return commit
}
