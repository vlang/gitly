module main

fn (app App) get_all_repo_branch_names(repo_id int) []string {
	branches := app.get_all_repo_branches(repo_id)

	return branches.map(it.name)
}
