module main

import veb
import os

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

	if commit_message == '' {
		ctx.error('Commit message is required')
		path := file_path
		return $veb.html('templates/edit_file.html')
	}

	mut actual_branch := branch_name
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

	mut actual_branch := branch_name
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

	// Write content to a temp file, then hash it into git
	tmp_file := '/tmp/gitly_newfile_${repo.id}'
	os.write_file(tmp_file, content) or {
		app.warn('Failed to write temp file: ${err}')
		return false
	}
	defer {
		os.rm(tmp_file) or {}
	}

	// 1. Hash the blob
	blob_hash := sh('git -C ${git_dir} hash-object -w ${tmp_file}')
	if blob_hash == '' {
		app.warn('hash-object failed')
		return false
	}

	// 2. Read the current tree for this branch (if it exists)
	mut parent_commit := ''
	existing_tree := sh('git -C ${git_dir} rev-parse "${branch}^{tree}"')
	has_existing_tree := existing_tree != ''

	// Get parent commit hash
	parent_commit = sh('git -C ${git_dir} rev-parse ${branch}')

	// 3. Build a new tree
	mut new_tree_hash := ''
	if has_existing_tree {
		tmp_index := '/tmp/gitly_index_${repo.id}'
		defer {
			os.rm(tmp_index) or {}
		}

		// Read existing tree into temp index
		r1 := os.execute('/bin/sh -c \'GIT_INDEX_FILE=${tmp_index} git -C ${git_dir} read-tree ${existing_tree}\'')
		if r1.exit_code != 0 {
			app.warn('read-tree failed: ${r1.output}')
			return false
		}

		// Add the new blob to the index
		r2 := os.execute('/bin/sh -c \'GIT_INDEX_FILE=${tmp_index} git -C ${git_dir} update-index --add --cacheinfo 100644,${blob_hash},${file_path}\'')
		if r2.exit_code != 0 {
			app.warn('update-index failed: ${r2.output}')
			return false
		}

		// Write the tree
		r3 := os.execute('/bin/sh -c \'GIT_INDEX_FILE=${tmp_index} git -C ${git_dir} write-tree\'')
		if r3.exit_code != 0 {
			app.warn('write-tree failed: ${r3.output}')
			return false
		}
		new_tree_hash = r3.output.trim_space()
	} else {
		// No existing tree — create from scratch using mktree
		tree_entry := '100644 blob ${blob_hash}\t${file_path}'
		tmp_tree := '/tmp/gitly_tree_${repo.id}'
		os.write_file(tmp_tree, tree_entry + '\n') or { return false }
		defer {
			os.rm(tmp_tree) or {}
		}
		r := os.execute('/bin/sh -c \'git -C ${git_dir} mktree < ${tmp_tree}\'')
		if r.exit_code != 0 {
			app.warn('mktree failed: ${r.output}')
			return false
		}
		new_tree_hash = r.output.trim_space()
	}

	if new_tree_hash == '' {
		app.warn('Failed to create tree')
		return false
	}

	// 4. Create a commit
	mut parent_flag := ''
	if parent_commit != '' {
		parent_flag = '-p ${parent_commit}'
	}

	commit_sh := 'GIT_AUTHOR_NAME="${author}" GIT_AUTHOR_EMAIL="${author}@gitly" GIT_COMMITTER_NAME="${author}" GIT_COMMITTER_EMAIL="${author}@gitly" git -C ${git_dir} commit-tree ${new_tree_hash} ${parent_flag} -m "${message}"'
	r4 := os.execute("/bin/sh -c '${commit_sh}'")
	if r4.exit_code != 0 {
		app.warn('commit-tree failed: ${r4.output}')
		return false
	}
	new_commit_hash := r4.output.trim_space()

	// 5. Update the branch ref
	r5 := os.execute('git -C ${git_dir} update-ref refs/heads/${branch} ${new_commit_hash}')
	if r5.exit_code != 0 {
		app.warn('update-ref failed: ${r5.output}')
		return false
	}

	app.info('File ${file_path} created with commit ${new_commit_hash}')
	return true
}

fn sh(cmd string) string {
	r := os.execute('/bin/sh -c \'${cmd}\'')
	if r.exit_code != 0 {
		return ''
	}
	return r.output.trim_space()
}
