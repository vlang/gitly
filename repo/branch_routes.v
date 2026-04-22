module main

import veb
import api

@['/api/v1/:user/:repo_name/branches/count']
fn (mut app App) handle_branch_count(username string, repo_name string) veb.Result {
	has_access := app.has_user_repo_read_access_by_repo_name(ctx, ctx.user.id, username,
		repo_name)

	if !has_access {
		return ctx.json_error('Not found')
	}

	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.json_error('Not found')
	}

	count := app.get_count_repo_branches(repo.id)

	return ctx.json(api.ApiBranchCount{
		success: true
		result:  count
	})
}

@['/:user/:repo/branches']
pub fn (mut app App) branches(username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or {
		return ctx.json_error('Not found')
	}
	branches := app.get_all_repo_branches(repo.id)
	return $veb.html()
}
