module main

import time

fn (mut app App) build_user_feed(user_id int) []FeedItem {
	mut feed := []FeedItem{}
	repo_ids := app.find_watching_repo_ids(user_id)
	where_repo_ids := repo_ids.map(it.str()).join(', ')

	commits, _ := app.db.exec('select author, hash, created_at, repo_id, branch_id, message from `Commit` where repo_id in (${where_repo_ids}) order by created_at desc limit ${user_feed_page_size}')
	mut item_id := 0

	for commit in commits {
		vals := commit.vals
		author_name := vals[0]
		commit_hash := vals[1]
		created_at_unix := vals[2].int()
		repo_id := vals[3].int()
		branch_id := vals[4].int()
		commit_message := vals[5]

		repo := app.find_repo_by_id(repo_id)
		repo_owner := app.get_username_by_id(repo.user_id) or { '' }
		branch := app.find_repo_branch_by_id(repo_id, branch_id)
		created_at := time.unix(created_at_unix)

		item := FeedItem{
			id: item_id++
			author_name: author_name
			created_at: created_at
			repo_name: repo.name
			repo_owner: repo_owner
			branch_name: branch.name
			message: '${commit_message} (${commit_hash})'
		}

		feed << item
	}

	return feed
}
