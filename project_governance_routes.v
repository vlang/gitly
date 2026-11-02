// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb

@['/:username/:repo_name/settings/members']
pub fn (mut app App) repo_members(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	members := app.find_project_members(repo.id)
	return $veb.html('templates/repo/members.html')
}

@['/:username/:repo_name/settings/members'; post]
pub fn (mut app App) handle_add_repo_member(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	target_name := ctx.form['member_username'].trim_space().to_lower()
	role := ctx.form['role'].trim_space().to_lower()
	target := app.get_user_by_username(target_name) or {
		ctx.error('That registered user does not exist')
		return app.repo_members(mut ctx, username, repo_name)
	}
	if !target.is_registered || target.is_blocked || !valid_project_member_role(role) {
		ctx.error('The member or role is invalid')
		return app.repo_members(mut ctx, username, repo_name)
	}
	if app.repo_access_level(target.id, repo) >= project_access_owner {
		ctx.error('The repository owner already has full access')
		return app.repo_members(mut ctx, username, repo_name)
	}
	app.add_project_member(repo.id, target.id, role) or {
		ctx.error('That user is already a direct project member')
		return app.repo_members(mut ctx, username, repo_name)
	}
	return ctx.redirect('/${username}/${repo_name}/settings/members')
}

@['/:username/:repo_name/settings/members/:member_id'; post]
pub fn (mut app App) handle_update_repo_member(mut ctx Context, username string, repo_name string, member_id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	role := ctx.form['role'].trim_space().to_lower()
	app.update_project_member_role(repo.id, member_id.int(), role) or {
		ctx.error('Could not update the project member')
		return app.repo_members(mut ctx, username, repo_name)
	}
	return ctx.redirect('/${username}/${repo_name}/settings/members')
}

@['/:username/:repo_name/settings/members/:member_id/delete'; post]
pub fn (mut app App) handle_delete_repo_member(mut ctx Context, username string, repo_name string, member_id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	app.remove_project_member(repo.id, member_id.int()) or {
		ctx.error('Could not remove the project member')
		return app.repo_members(mut ctx, username, repo_name)
	}
	return ctx.redirect('/${username}/${repo_name}/settings/members')
}

@['/:username/:repo_name/settings/branches']
pub fn (mut app App) protected_branches(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	rules := app.find_protected_branches(repo.id)
	branches := app.get_all_repo_branches(repo.id)
	return $veb.html('templates/repo/protected_branches.html')
}

@['/:username/:repo_name/settings/branches'; post]
pub fn (mut app App) handle_protect_branch(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	pattern := ctx.form['pattern'].trim_space()
	push_access := ctx.form['push_access'].int()
	merge_access := ctx.form['merge_access'].int()
	app.protect_branch(repo.id, pattern, push_access, merge_access) or {
		ctx.error('The branch pattern is invalid or already protected')
		return app.protected_branches(mut ctx, username, repo_name)
	}
	return ctx.redirect('/${username}/${repo_name}/settings/branches')
}

@['/:username/:repo_name/settings/branches/:rule_id'; post]
pub fn (mut app App) handle_update_protected_branch(mut ctx Context, username string, repo_name string, rule_id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	app.update_protected_branch(repo.id, rule_id.int(), ctx.form['push_access'].int(),
		ctx.form['merge_access'].int()) or {
		ctx.error('Could not update the protected branch rule')
		return app.protected_branches(mut ctx, username, repo_name)
	}
	return ctx.redirect('/${username}/${repo_name}/settings/branches')
}

@['/:username/:repo_name/settings/branches/:rule_id/delete'; post]
pub fn (mut app App) handle_unprotect_branch(mut ctx Context, username string, repo_name string, rule_id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	app.unprotect_branch(repo.id, rule_id.int()) or {
		ctx.error('Could not remove the protected branch rule')
		return app.protected_branches(mut ctx, username, repo_name)
	}
	return ctx.redirect('/${username}/${repo_name}/settings/branches')
}

@['/:username/:repo_name/settings/approvals'; post]
pub fn (mut app App) handle_update_repo_approvals(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.not_found()
	}
	app.set_repo_required_approvals(repo.id, ctx.form['required_approvals'].int()) or {
		ctx.error('Required approvals must be between 0 and 100')
		return ctx.redirect('/${username}/${repo_name}/settings')
	}
	return ctx.redirect('/${username}/${repo_name}/settings')
}
