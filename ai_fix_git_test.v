module main

import encoding.base64
import git
import os
import rand

const ai_patch_example = 'diff --git a/answer.txt b/answer.txt\n--- a/answer.txt\n+++ b/answer.txt\n@@ -1 +1 @@\n-broken\n+fixed\n'

fn ai_patch_git(args []string) string {
	result := git.Git.exec(args)
	assert result.exit_code == 0, result.output
	return result.output.trim_space()
}

fn ai_patch_fixture() !(string, Repo, string) {
	root := os.join_path(os.temp_dir(), 'gitly_ai_patch_${rand.ulid()}')
	os.mkdir_all(root)!
	work := os.join_path(root, 'work')
	bare := os.join_path(root, 'project.git')
	ai_patch_git(['init', '-b', 'main', work])
	ai_patch_git(['-C', work, 'config', 'user.name', 'AI Test'])
	ai_patch_git(['-C', work, 'config', 'user.email', 'ai@example.test'])
	ai_patch_git(['-C', work, 'config', 'core.autocrlf', 'false'])
	os.write_file(os.join_path(work, 'answer.txt'), 'broken\n')!
	os.write_file(os.join_path(work, 'windows.txt'), 'broken\r\n')!
	os.write_file(os.join_path(work, 'large.txt'), 'context\n'.repeat(20_000))!
	ai_patch_git(['-C', work, 'add', '.'])
	ai_patch_git(['-C', work, 'commit', '-m', 'Initial source'])
	ai_patch_git(['-C', work, 'branch', 'feature'])
	ai_patch_git(['clone', '--bare', work, bare])
	head := ai_patch_git(['-C', bare, 'rev-parse', 'feature'])
	return root, Repo{ git_dir: bare }, head
}

fn ai_patch_is_rejected(repo Repo, head string, patch string) bool {
	prepare_ai_fix_patch(repo, head, patch) or { return true }
	return false
}

fn test_ai_patch_preview_is_isolated_and_commit_only_advances_source() {
	root, repo, head := ai_patch_fixture()!
	defer { os.rmdir_all(root) or {} }
	ai_patch_git(['-C', repo.git_dir, 'read-tree', head])
	index := os.read_bytes(os.join_path(repo.git_dir, 'index'))!
	$if !windows {
		// These hooks really run for read-tree/write-tree/update-ref unless
		// every operation disables them. No hook may run during either stage.
		for hook in ['post-index-change', 'reference-transaction'] {
			path := os.join_path(repo.git_dir, 'hooks', hook)
			os.write_file(path, '#!/bin/sh\nprintf hook >> "${root}/hook-fired"\n')!
			os.chmod(path, 0o755)!
		}
	}
	prepared := prepare_ai_fix_patch(repo, head, ai_patch_example)!
	assert is_full_commit_oid(prepared.tree_oid)
	assert prepared.patch.contains('+fixed\n')
	assert ai_patch_git(['-C', repo.git_dir, 'rev-parse', 'feature']) == head
	assert ai_patch_git(['-C', repo.git_dir, 'show', 'feature:answer.txt']) == 'broken'
	assert os.read_bytes(os.join_path(repo.git_dir, 'index'))! == index
	assert !os.exists(os.join_path(root, 'hook-fired'))

	commit := commit_ai_fix_patch(repo, 'feature', head, prepared.patch, 'alice')!
	assert commit != head
	assert ai_patch_git(['-C', repo.git_dir, 'rev-parse', 'feature']) == commit
	assert ai_patch_git(['-C', repo.git_dir, 'rev-parse', '${commit}^']) == head
	assert ai_patch_git(['-C', repo.git_dir, 'rev-parse', 'main']) == head
	assert ai_patch_git(['-C', repo.git_dir, 'show', 'feature:answer.txt']) == 'fixed'
	assert ai_patch_git(['-C', repo.git_dir, 'show', '-s', '--format=%an', commit]) == 'alice'
	assert os.read_bytes(os.join_path(repo.git_dir, 'index'))! == index
	assert !os.exists(os.join_path(root, 'hook-fired'))
	// A repeated/stale apply cannot overwrite the resulting branch.
	mut stale_rejected := false
	commit_ai_fix_patch(repo, 'feature', head, ai_patch_example, 'alice') or {
		stale_rejected = true
	}
	assert stale_rejected
	assert ai_patch_git(['-C', repo.git_dir, 'rev-parse', 'feature']) == commit
}

fn test_ai_patch_rejects_unsafe_paths_and_non_text_changes() {
	root, repo, head := ai_patch_fixture()!
	defer { os.rmdir_all(root) or {} }
	for path in ['../outside.txt', '/outside.txt', '.git/config', 'nested/.GiT/config', 'git~1/config',
		'nested/.git./config', 'C:\\outside.txt'] {
		assert !ai_fix_safe_path(path)
		patch := 'diff --git a/${path} b/${path}\nnew file mode 100644\n--- /dev/null\n+++ b/${path}\n@@ -0,0 +1 @@\n+unsafe\n'
		assert ai_patch_is_rejected(repo, head, patch), path
	}
	assert ai_fix_safe_path('src/safe file.v')
	assert ai_patch_is_rejected(repo, head,
		'diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+answer.txt\n')
	assert ai_patch_is_rejected(repo, head,
		'diff --git a/module b/module\nnew file mode 160000\n--- /dev/null\n+++ b/module\n@@ -0,0 +1 @@\n+Subproject commit ${head}\n')
	assert ai_patch_is_rejected(repo, head,
		'diff --git a/answer.txt b/answer.txt\nold mode 100644\nnew mode 100755\n')
	assert ai_patch_is_rejected(repo, head,
		'diff --git a/answer.txt b/answer.txt\nGIT binary patch\nliteral 0\nHcmV?d00001\n')
	assert ai_patch_is_rejected(repo, head, ai_patch_example.replace('-broken', '-missing'))
	assert ai_patch_is_rejected(repo, head, '')
	assert ai_patch_is_rejected(repo, head, ai_patch_example + '\x00')
	assert ai_patch_is_rejected(repo, head, ai_patch_example + 'x'.repeat(128 * 1024))
	assert ai_patch_git(['-C', repo.git_dir, 'rev-parse', 'feature']) == head
	assert !os.exists(os.join_path(root, 'outside.txt'))
}

fn test_ai_patch_supports_regular_file_additions_and_deletions() {
	root, repo, head := ai_patch_fixture()!
	defer { os.rmdir_all(root) or {} }
	patch := 'diff --git a/answer.txt b/answer.txt\ndeleted file mode 100644\n--- a/answer.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-broken\n' +
		'diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+fixed\n'
	prepared := prepare_ai_fix_patch(repo, head, patch)!
	assert ai_patch_git(['-C', repo.git_dir, 'show', '${prepared.tree_oid}:new.txt']) == 'fixed'
	assert git.Git.exec_in_dir(repo.git_dir, ['cat-file', '-e', '${prepared.tree_oid}:answer.txt']).exit_code != 0
}

fn test_ai_patch_form_encoding_preserves_crlf_bytes() {
	root, repo, head := ai_patch_fixture()!
	defer { os.rmdir_all(root) or {} }
	patch := 'diff --git a/windows.txt b/windows.txt\n--- a/windows.txt\n+++ b/windows.txt\n@@ -1 +1 @@\n-broken\r\n+fixed\r\n'
	prepared := prepare_ai_fix_patch(repo, head, patch)!
	encoded := base64.encode_str(prepared.patch)
	decoded := ai_fix_decode_patch(encoded)!
	assert decoded == prepared.patch
	commit := commit_ai_fix_patch(repo, 'feature', head, decoded, 'alice')!
	content := git.Git.exec_in_dir(repo.git_dir, ['show', '${commit}:windows.txt'])
	assert content.exit_code == 0
	assert content.output == 'fixed\r\n'
	for invalid in ['', 'not base64!', 'AAAA=', encoded + '\n'] {
		mut rejected := false
		ai_fix_decode_patch(invalid) or { rejected = true }
		assert rejected
	}
}

fn test_ai_context_limits_output_and_reads_only_small_regular_blobs() {
	root, repo, head := ai_patch_fixture()!
	defer { os.rmdir_all(root) or {} }
	assert ai_fix_source_file(repo, head, 'answer.txt') or { panic('missing source file') } ==
		AiFixSourceFile{ path: 'answer.txt', content: 'broken\n' }
	assert ai_fix_source_file(repo, head, 'large.txt') == none
	assert ai_fix_source_file(repo, head, '../answer.txt') == none
	assert ai_fix_source_file(repo, head, 'missing.txt') == none
	bounded := ai_fix_read_git_context(repo, ['show', '${head}:large.txt'], 1000)!
	assert bounded.len == 1001
	assert ai_fix_trim_text(bounded, 1000).ends_with('[truncated]')
	assert ai_fix_trim_text('aéz', 2) == 'a\n[truncated]'
}

fn test_ai_context_uses_failed_steps_and_caps_logs() {
	run := CiRunDetail{
		error_message: 'build failed'
		jobs:          [CiJobDetail{
			name:  'test'
			steps: [
				CiStepDetail{ status: 'success', output: 'unrelated success output' },
				CiStepDetail{
					status:    'failure'
					command:   'v test .'
					exit_code: 1
					output:    'earlier output\n'.repeat(4000) + 'answer.txt:1: test failed\n'
				},
			]
		}]
	}
	logs := ai_fix_failed_logs(run)
	assert logs.contains('build failed')
	assert logs.contains('answer.txt:1: test failed')
	assert logs.contains('v test .')
	assert !logs.contains('unrelated success output')
	assert logs.len < 33 * 1024
}
