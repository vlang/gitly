module main

import veb
import api

@['/api/v1/:user/:repo_name/branches/count']
fn (mut app App) handle_branch_count(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}

	count := app.get_count_repo_branches(repo.id)

	return ctx.json(api.ApiBranchCount{
		success: true
		result: count
	})
}

@['/:user/:repo/branches']
pub fn (mut app App) branches(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.json_error('Not found')
	}
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	mut branches := app.get_all_repo_branches(repo.id)
	for mut branch in branches {
		branch.is_protected = app.branch_is_protected(repo.id, branch.name)
		branch.can_delete = ctx.logged_in && branch.name != repo.primary_branch && !branch.is_protected && app.user_can_push_branch(ctx.user.id, repo, branch.name)
	}
	can_create := ctx.logged_in && app.user_can_write_repo(ctx.user.id, repo)
	return $veb.html()
}

@['/:username/:repo_name/branches'; post]
pub fn (mut app App) handle_create_branch(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	name := ctx.form['name'].trim_space()
	if !app.user_can_write_repo(ctx.user.id, repo) || !app.user_can_push_branch(ctx.user.id, repo, name) {
		return ctx.not_found()
	}
	app.create_repository_branch(repo, name, ctx.form['source']) or {
		ctx.error(err.msg())
		return app.branches(mut ctx, username, repo_name)
	}
	app.dispatch_webhook(repo.id, 'push', WebhookPushPayload{
		repo: '${username}/${repo_name}'
		ref: 'refs/heads/${name}'
		author: ctx.user.username
	})
	return ctx.redirect('/${username}/${repo_name}/tree/${repo_url_path(name)}')
}

@['/:username/:repo_name/branches/delete'; post]
pub fn (mut app App) handle_delete_branch(mut ctx Context, username string, repo_name string) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	name := ctx.form['name'].trim_space()
	if !app.user_can_push_branch(ctx.user.id, repo, name) {
		return ctx.not_found()
	}
	app.delete_repository_branch(repo, name) or {
		ctx.error(err.msg())
		return app.branches(mut ctx, username, repo_name)
	}
	app.dispatch_webhook(repo.id, 'push', WebhookPushPayload{
		repo: '${username}/${repo_name}'
		ref: 'refs/heads/${name}'
		author: ctx.user.username
	})
	return ctx.redirect('/${username}/${repo_name}/branches')
}

@['/api/v1/repos/:username/:repo_name/branches']
pub fn (mut app App) api_v1_repo_branches(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	caller := app.api_user_from_ctx(ctx) or { User{} }
	if !app.user_has_repo_read_access(caller.id, repo) {
		return ctx.api_not_found()
	}
	mut branches := app.get_all_repo_branches(repo.id)
	mut result := []ApiBranchView{cap: branches.len}
	for mut branch in branches {
		branch.is_protected = app.branch_is_protected(repo.id, branch.name)
		result << branch.to_api(repo)
	}
	return ctx.json(result)
}

@['/api/v1/repos/:username/:repo_name/branches'; post]
pub fn (mut app App) api_v1_create_branch(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	name := ctx.form['name'].trim_space()
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	if !app.user_can_write_repo(user.id, repo) || !app.user_can_push_branch(user.id, repo, name) {
		return ctx.api_error_response(403, 'Forbidden', 'Developer branch access is required')
	}
	branch := app.create_repository_branch(repo, name, ctx.form['source']) or {
		return ctx.api_error_response(400, 'Bad Request', err.msg())
	}
	app.dispatch_webhook(repo.id, 'push', WebhookPushPayload{
		repo: '${username}/${repo_name}'
		ref: 'refs/heads/${name}'
		author: user.username
	})
	return ctx.json(branch.to_api(repo))
}

@['/api/v1/repos/:username/:repo_name/branches/delete'; post]
pub fn (mut app App) api_v1_delete_branch(mut ctx Context, username string, repo_name string) veb.Result {
	user := app.api_user_from_ctx(ctx) or { return ctx.api_unauthorized() }
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.api_not_found()
	}
	name := ctx.form['name'].trim_space()
	if !app.user_has_repo_read_access(user.id, repo) {
		return ctx.api_not_found()
	}
	if !app.user_can_push_branch(user.id, repo, name) {
		return ctx.api_error_response(403, 'Forbidden', 'Developer branch access is required')
	}
	app.delete_repository_branch(repo, name) or {
		return ctx.api_error_response(400, 'Bad Request', err.msg())
	}
	app.dispatch_webhook(repo.id, 'push', WebhookPushPayload{
		repo: '${username}/${repo_name}'
		ref: 'refs/heads/${name}'
		author: user.username
	})
	return ctx.api_success_response()
}
