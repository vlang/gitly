module main

import veb
import os
import git

// GET /:username/:repo_name/new/:branch_name - Show create file form
@['/:username/:repo_name/new/:branch_name']
pub fn (mut app App) new_file(username string, repo_name string, branch_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !ctx.logged_in || repo.user_id != ctx.user.id {
		return ctx.redirect_to_repository(username, repo_name)
	}

	default_content := ''
	default_filename := ''
	return $veb.html('templates/new_file.html')
}

// GET /:username/:repo_name/new-ci-file - Show create .gitly-ci.yml form (pre-filled)
@['/:username/:repo_name/new-ci-file']
pub fn (mut app App) new_ci_file(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !ctx.logged_in || repo.user_id != ctx.user.id {
		return ctx.redirect_to_repository(username, repo_name)
	}

	branch_name := repo.primary_branch
	default_filename := '.gitly-ci.yml'
	default_content := 'jobs:
  build:
    steps:
      - name: Build
        run: echo "hello world"
      - name: Test
        run: echo "running tests"
'
	return $veb.html('templates/new_file.html')
}

// GET /:username/:repo_name/edit/:branch_name/:path... - Show edit file form
@['/:username/:repo_name/edit/:branch_name/:path...']
pub fn (mut app App) edit_file(username string, repo_name string, branch_name string, path string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !ctx.logged_in || repo.user_id != ctx.user.id {
		return ctx.redirect_to_repository(username, repo_name)
	}

	file_content := repo.read_file(branch_name, path)

	return $veb.html('templates/edit_file.html')
}

// POST /:username/:repo_name/update-file - Save edited file
@['/:username/:repo_name/update-file'; post]
pub fn (mut app App) handle_update_file(username string, repo_name string) veb.Result {
	mut repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.not_found()
	}

	if !ctx.logged_in || repo.user_id != ctx.user.id {
		return ctx.redirect_to_repository(username, repo_name)
	}

	file_path := ctx.form['file_path']
	file_content := ctx.form['file_content']
	branch_name := ctx.form['branch']
	commit_message := ctx.form['commit_message']
	mut actual_branch := ''

	if commit_message == '' {
		ctx.error('Commit message is required')
		path := file_path
		return $veb.html('templates/edit_file.html')
	}

	actual_branch = branch_name
	if actual_branch == '' {
		actual_branch = repo.primary_branch
	}

	success := app.create_file_in_bare_repo(mut repo, actual_branch, file_path, file_content,
		commit_message, ctx.user.username)

	if !success {
		ctx.error('Failed to save file')
		path := file_path
		return $veb.html('templates/edit_file.html')
	}

	// Clear cached files so the updated file shows up
	app.delete_repository_files_in_branch(repo.id, actual_branch) or {}

	app.update_repo_after_push(repo.id, actual_branch) or {
		app.warn('Failed to update repo after file edit: ${err}')
	}

	// Trigger CI if applicable
	if file_path == '.gitly-ci.yml' {
		spawn app.trigger_ci_with_config(repo.id, actual_branch, file_content)
	} else {
		spawn app.trigger_ci_if_configured(repo.id, actual_branch)
	}

	return ctx.redirect('/${username}/${repo_name}/blob/${actual_branch}/${file_path}')
}

// POST /:username/:repo_name/create-file - Create a file in the repo
@['/:username/:repo_name/create-file'; post]
pub fn (mut app App) handle_create_file(username string, repo_name string) veb.Result {
	mut repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.not_found()
	}

	if !ctx.logged_in || repo.user_id != ctx.user.id {
		return ctx.redirect_to_repository(username, repo_name)
	}

	file_path := ctx.form['file_path']
	file_content := ctx.form['file_content']
	branch_name := ctx.form['branch']
	commit_message := ctx.form['commit_message']
	mut actual_branch := ''

	if file_path == '' {
		ctx.error('File path is required')
		default_content := file_content
		default_filename := file_path
		return $veb.html('templates/new_file.html')
	}

	if commit_message == '' {
		ctx.error('Commit message is required')
		default_content := file_content
		default_filename := file_path
		return $veb.html('templates/new_file.html')
	}

	// Sanitize file path
	if file_path.contains('..') || file_path.contains('&') || file_path.contains(';') {
		ctx.error('Invalid file path')
		default_content := file_content
		default_filename := file_path
		return $veb.html('templates/new_file.html')
	}

	actual_branch = branch_name
	if actual_branch == '' {
		actual_branch = repo.primary_branch
	}

	success := app.create_file_in_bare_repo(mut repo, actual_branch, file_path, file_content,
		commit_message, ctx.user.username)

	if !success {
		ctx.error('Failed to create file')
		default_content := file_content
		default_filename := file_path
		return $veb.html('templates/new_file.html')
	}

	// Clear cached files so the new file shows up
	app.delete_repository_files_in_branch(repo.id, actual_branch) or {}

	// Update repo data
	app.update_repo_after_push(repo.id, actual_branch) or {
		app.warn('Failed to update repo after file creation: ${err}')
	}

	// Trigger CI — if we just created .gitly-ci.yml, pass the content directly
	if file_path == '.gitly-ci.yml' {
		spawn app.trigger_ci_with_config(repo.id, actual_branch, file_content)
	} else {
		spawn app.trigger_ci_if_configured(repo.id, actual_branch)
	}

	return ctx.redirect('/${username}/${repo_name}')
}

// Creates a file in a bare git repo using plumbing commands
fn (mut app App) create_file_in_bare_repo(mut repo Repo, branch string, file_path string, content string, message string, author string) bool {
	git_dir := repo.git_dir
	app.info('Creating file ${file_path} in ${git_dir} on branch ${branch}')

	// Validate untrusted inputs before they reach git. Every git invocation
	// below passes its arguments as an array (never through a shell), but we
	// still reject values git itself could treat as flags/refs or that contain
	// control characters. This guards both the create-file and update-file
	// routes, which both funnel through here.
	if !is_safe_ref(branch) {
		app.warn('Refusing to write file: invalid branch name "${branch}"')
		return false
	}
	if !is_valid_repo_file_path(file_path) {
		app.warn('Refusing to write file: invalid file path "${file_path}"')
		return false
	}

	// Write content to a temp file, then hash it into git
	tmp_file := os.join_path(os.temp_dir(), 'gitly_newfile_${repo.id}_${os.getpid()}')
	os.write_file(tmp_file, content) or {
		app.warn('Failed to write temp file: ${err}')
		return false
	}
	defer {
		os.rm(tmp_file) or {}
	}

	// 1. Hash the blob into the object store
	hash_res := git.Git.exec_in_dir(git_dir, ['hash-object', '-w', tmp_file])
	if hash_res.exit_code != 0 {
		app.warn('hash-object failed: ${hash_res.output}')
		return false
	}
	blob_hash := hash_res.output.trim_space()
	if blob_hash == '' {
		app.warn('hash-object produced no hash')
		return false
	}

	// 2. Find the current tree and parent commit for this branch (both may be
	//    empty when committing to a brand-new branch).
	tree_res := git.Git.exec_in_dir(git_dir, ['rev-parse', '${branch}^{tree}'])
	existing_tree := if tree_res.exit_code == 0 { tree_res.output.trim_space() } else { '' }
	has_existing_tree := existing_tree != ''

	parent_res := git.Git.exec_in_dir(git_dir, ['rev-parse', branch])
	parent_commit := if parent_res.exit_code == 0 { parent_res.output.trim_space() } else { '' }

	// 3. Build the new tree inside an isolated temp index, so neither the
	//    repo's own index nor a concurrent edit of the same repo is affected.
	//    Starting from an empty index (no read-tree) handles the new-branch
	//    case without needing `mktree`.
	tmp_index := os.join_path(os.temp_dir(), 'gitly_index_${repo.id}_${os.getpid()}')
	os.rm(tmp_index) or {}
	defer {
		os.rm(tmp_index) or {}
	}
	index_env := {
		'GIT_INDEX_FILE': tmp_index
	}

	if has_existing_tree {
		read_res := git.Git.exec_in_dir_with_env(git_dir, ['read-tree', existing_tree], index_env)
		if read_res.exit_code != 0 {
			app.warn('read-tree failed: ${read_res.output}')
			return false
		}
	}

	add_res := git.Git.exec_in_dir_with_env(git_dir, ['update-index', '--add', '--cacheinfo',
		'100644,${blob_hash},${file_path}'], index_env)
	if add_res.exit_code != 0 {
		app.warn('update-index failed: ${add_res.output}')
		return false
	}

	write_res := git.Git.exec_in_dir_with_env(git_dir, ['write-tree'], index_env)
	if write_res.exit_code != 0 {
		app.warn('write-tree failed: ${write_res.output}')
		return false
	}
	new_tree_hash := write_res.output.trim_space()
	if new_tree_hash == '' {
		app.warn('Failed to create tree')
		return false
	}

	// 4. Create the commit. The message and author are passed as plain
	//    arguments / environment values, so any shell metacharacters they
	//    contain are inert.
	mut commit_args := ['commit-tree', new_tree_hash]
	if parent_commit != '' {
		commit_args << ['-p', parent_commit]
	}
	commit_args << ['-m', message]
	commit_env := {
		'GIT_AUTHOR_NAME':     author
		'GIT_AUTHOR_EMAIL':    '${author}@gitly'
		'GIT_COMMITTER_NAME':  author
		'GIT_COMMITTER_EMAIL': '${author}@gitly'
	}
	r4 := git.Git.exec_in_dir_with_env(git_dir, commit_args, commit_env)
	if r4.exit_code != 0 {
		app.warn('commit-tree failed: ${r4.output}')
		return false
	}
	new_commit_hash := r4.output.trim_space()

	// 5. Update the branch ref
	r5 := git.Git.exec_in_dir(git_dir, ['update-ref', 'refs/heads/${branch}', new_commit_hash])
	if r5.exit_code != 0 {
		app.warn('update-ref failed: ${r5.output}')
		return false
	}

	app.info('File ${file_path} created with commit ${new_commit_hash}')
	return true
}

fn sh(cmd string) string {
	r := git.Git.exec_shell(cmd)
	if r.exit_code != 0 {
		return ''
	}
	return r.output.trim_space()
}

// is_valid_repo_file_path rejects empty/over-long paths, absolute paths, leading
// dashes, parent-directory traversal, and any control characters (including NUL
// and newlines).
fn is_valid_repo_file_path(path string) bool {
	if path.len == 0 || path.len > 4096 {
		return false
	}
	if path.starts_with('/') || path.starts_with('-') || path.contains('..') {
		return false
	}
	for c in path {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	return true
}
