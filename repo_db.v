// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

fn (mut app App) create_table(name string, fields []string) {
	app.db.exec('create table if not exists `$name` (' + fields.join(',') + ')')
}

fn (mut app App) create_tables() {
	sql app.db {
		create table Repo
	}
	// unix time default now
	sql app.db {
		create table File
	} // missing ON CONFLIC REPLACE
	//"created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Issue
	}
	//"created_at int default (strftime('%s', 'now'))"
	sql app.db {
		create table Commit
	}
	// author text default '' is to to avoid joins
	sql app.db {
		create table LangStat
	}
	sql app.db {
		create table User
	}
	sql app.db {
		create table Email
	}
	sql app.db {
		create table Contributor
	}
	sql app.db {
		create table Tag
	}
	sql app.db {
		create table Release
	}
	sql app.db {
		create table SshKey
	}
	sql app.db {
		create table Comment
	}
	sql app.db {
		create table Branch
	}
	sql app.db {
		create table Visit
	}
	sql app.db {
		create table GitlySettings
	}
	sql app.db {
		create table Token
	}
	sql app.db {
		create table SecurityLog
	}
}

fn (mut app App) update_repo_in_db(repo &Repo) {
	id := repo.id
	desc := repo.description
	nr_views := repo.nr_views
	webhook_secret := repo.webhook_secret
	nr_tags := repo.nr_tags
	is_public := if repo.is_public { 1 } else { 0 }
	nr_open_issues := repo.nr_open_issues
	nr_open_prs := repo.nr_open_prs
	nr_branches := repo.nr_branches
	nr_releases := repo.nr_releases
	nr_contributors := repo.nr_contributors
	nr_commits := repo.nr_commits
	sql app.db {
		update Repo set description = desc, nr_views = nr_views, is_public = is_public, webhook_secret = webhook_secret,
		nr_tags = nr_tags, nr_open_issues = nr_open_issues, nr_open_prs = nr_open_prs,
		nr_releases = nr_releases, nr_contributors = nr_contributors, nr_commits = nr_commits,
		nr_branches = nr_branches where id == id
	}
}

fn (mut app App) find_repo_by_name(user int, name string) ?Repo {
	x := sql app.db {
		select from Repo where name == name && user_id == user limit 1
	}
	if x.id == 0 {
		return none
	}
	return x
}

fn (mut app App) nr_user_repos(user_id int) int {
	return sql app.db {
		select count from Repo where user_id == user_id
	}
}

fn (mut app App) find_user_repos(user_id int) []Repo {
	return sql app.db {
		select from Repo where user_id == user_id
	}
}

fn (mut app App) nr_user_public_repos(user_id int) int {
	return sql app.db {
		select count from Repo where user_id == user_id && is_public == true
	}
}

fn (mut app App) find_user_public_repos(user_id int) []Repo {
	return sql app.db {
		select from Repo where user_id == user_id && is_public == true
	}
}

fn (mut app App) find_repo_by_id(repo_id int) Repo {
	return sql app.db {
		select from Repo where id == repo_id
	}
}

fn (mut app App) exists_user_repo(user string, name string) bool {
	if user.len == 0 || name.len == 0 {
		app.info('User or repo was not found')
		return false
	}
	u := app.find_user_by_username(user) or {
		app.info('User was not found')
		return false
	}
	app.repo = app.find_repo_by_name(u.id, name) or {
		app.info('Repo was not found')
		return false
	}
	app.repo.lang_stats = app.find_repo_lang_stats(app.repo.id)
	app.html_path = app.repo.html_path_to(app.path, app.repo.primary_branch)
	return true
}

fn (mut app App) retrieve_repo(id int) Repo {
	return app.repo
}

fn (mut app App) inc_repo_views(repo_id int) {
	sql app.db {
		update Repo set nr_views = nr_views + 1 where id == repo_id
	}
}

fn (mut app App) inc_file_views(file_id int) {
	sql app.db {
		update File set nr_views = nr_views + 1 where id == file_id
	}
}

fn (mut app App) inc_repo_issues(repo_id int) {
	sql app.db {
		update Repo set nr_open_issues = nr_open_issues + 1 where id == repo_id
	}
	app.repo.nr_open_issues++
}

fn (mut app App) update_repo_nr_commits(repo_id int, nr_commits int) {
	sql app.db {
		update Repo set nr_commits = nr_commits where id == repo_id
	}
	app.repo.nr_commits = nr_commits
}

fn (mut app App) update_repo_webhook(repo_id int, webhook string) {
	sql app.db {
		update Repo set webhook_secret = webhook where id == repo_id
	}
}

fn (mut app App) update_repo_nr_contributor(repo_id int, nr_contributors int) {
	sql app.db {
		update Repo set nr_contributors = nr_contributors where id == repo_id
	}
	app.repo.nr_contributors = nr_contributors
}

fn (mut app App) insert_repo(repo Repo) {
	sql app.db {
		insert repo into Repo
	}
}

fn (mut app App) delete_repo(id int, path string, name string) {
	// Remove repo
	sql app.db {
		delete from Repo where id == id
	}
	app.info('Removed repo entry ($id, $name)')
	// Remove all commits
	sql app.db {
		delete from Commit where repo_id == id
	}
	app.info('Removed repo commits ($id, $name)')
	// Remove all issues & prs
	app.delete_repo_issues(id)
	app.info('Removed repo issues ($id, $name)')
	// Remove all branches
	app.delete_repo_branches(id)
	app.info('Removed repo branches ($id, $name)')
	// Remove all releases
	app.delete_repo_releases(id)
	app.info('Removed repo releases ($id, $name)')
	// Remove all files
	app.delete_repo_files(id)
	app.info('Removed repo files ($id, $name)')
	// Remove physical files
	app.delete_repo_folder(path)
	app.info('Removed repo folder ($id, $name)')
}

fn (mut app App) move_repo_to_user(repo_id int, user_id int, user_name string) {
	sql app.db {
		update Repo set user_id = user_id, user_name = user_name where id == repo_id
	}
}

fn (mut app App) user_has_repo(user_id int, repo_name string) bool {
	count := sql app.db {
		select count from Repo where user_id == user_id && name == repo_name
	}
	return count >= 0
}
