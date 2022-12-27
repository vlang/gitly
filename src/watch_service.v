module main

fn (mut app App) watch_repo(repo_id int, user_id int) {
	watch := Watch{
		repo_id: repo_id
		user_id: user_id
	}

	sql app.db {
		insert watch into Watch
	}
}

fn (mut app App) get_count_repo_watchers(repo_id int) int {
	return sql app.db {
		select count from Watch where repo_id == repo_id
	}
}

fn (mut app App) find_watching_repo_ids(user_id int) []int {
	watch_list := sql app.db {
		select from Watch where user_id == user_id
	}

	return watch_list.map(it.repo_id)
}

fn (mut app App) toggle_repo_watcher_status(repo_id int, user_id int) {
	is_watching := app.check_repo_watcher_status(repo_id, user_id)

	if is_watching {
		app.unwatch_repo(repo_id, user_id)
	} else {
		app.watch_repo(repo_id, user_id)
	}
}

fn (mut app App) check_repo_watcher_status(repo_id int, user_id int) bool {
	watch := sql app.db {
		select from Watch where repo_id == repo_id && user_id == user_id limit 1
	}

	return watch.id != 0
}

fn (mut app App) unwatch_repo(repo_id int, user_id int) {
	sql app.db {
		delete from Watch where repo_id == repo_id && user_id == user_id
	}
}
