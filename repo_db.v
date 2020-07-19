// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

fn (mut app App) create_table(name string, fields []string) {
	app.db.exec('create table if not exists `$name` (' + fields.join(',') + ')')
}

fn (mut app App) create_tables() {
	app.create_table('Repo', [
		'id integer primary key'
		"git_dir text default ''"
		"name text default ''"
		"description text default ''"
		'user_id int default 0'
		"user_name text default ''"
		'primary_branch text default ""'
		'nr_views int default 0'
		'nr_commits int default 0'
		'nr_open_issues int default 0'
		'nr_tags int default 0'
		'nr_releases int default 0'
		'nr_open_prs int default 0'
		'webhook_secret text default ""'
		'nr_branches int default 0'
		'nr_contributors int default 0'
		"created_at int default (strftime('%s', 'now'))"
	])
    // unix time default now
	app.create_table('File', [
		'id integer primary key'
		"name text default ''"
		'repo_id int default 0'
		"parent_path text default ''"
		"branch text default ''"
		'is_dir int default 0'
		"last_hash text default ''"
		"last_msg text default ''"
		"last_time int default 0"
		'size int default 0'
		'nr_contributors int default 0'
		'nr_views int default 0'
		'UNIQUE(parent_path, name, repo_id, branch) ON CONFLICT REPLACE'
	])
	//"created_at int default (strftime('%s', 'now'))"
	app.create_table('Issue', [
		'id integer primary key'
		'author_id int default 0'
		'is_pr int default 0'
		'repo_id int default 0'
		"title text default ''"
		"text text default ''"
		'created_at integer default 0'
		'nr_comments int default 0'
	])
	//		"created_at int default (strftime('%s', 'now'))"
	app.create_table('Commit', [
		'id integer primary key'
		'author_id int default 0'
		"author text default ''"
		"hash text default ''"
		'repo_id int default 0'
		"message text default ''"
		"created_at int default (strftime('%s', 'now'))"
		'UNIQUE(hash, repo_id)'
	])
	// author text default '' is to to avoid joins
	app.create_table('LangStat', [
		'id integer primary key'
		'repo_id int default 0'
		'name text default ""'
		'nr_lines int default 0'
		'pct int default 0'
		'color text default ""'
		'UNIQUE(repo_id, name) ON CONFLICT REPLACE'
	])
	app.create_table('User', [
		'id integer primary key'
		'name text default ""'
		'username text default ""'
		'password text default ""'
		'avatar text default ""'
		'nr_posts integer default 0'
		'last_post_time integer default 0'
		'is_github int default 0'
		'is_blocked int default 0'
		'is_registered int default 0'
		'is_admin int default 0'
		'login_attempts int default 0'
		'UNIQUE(username)'
		])
	app.create_table('Email', [
		'id integer primary key'
		'user integer default 0'
		'email text default ""'
		'UNIQUE(email)'
	])
	app.create_table('Contributor', [
		'id integer primary key'
		'user integer default 0'
		'repo integer default 0'
		'UNIQUE(user, repo)'
	])
	app.create_table('Tag', [
		'id integer primary key'
		'name text default ""'
		'hash text default ""'
		'user_id integer default 0'
		'repo_id integer default 0'
		'date integer default 0'
		'UNIQUE(name, repo_id)'
	])
	app.create_table('Release', [
		'id integer primary key'
		'tag_id integer not null'
		'repo_id integer not null'
		'notes text default ""'
		'UNIQUE(tag_id, repo_id)'
	])
	app.create_table('SshKey', [
		'id integer primary key'
		'user integer default 0'
		'title text default ""'
		'sshkey text default ""'
		'is_deleted integer default 0'
	])
	app.create_table('Comment', [
		'id integer primary key'
		'author_id integer default 0'
		'issue_id integer default 0'
		'created_at integer default 0'
		'text text default ""'
	])
	app.create_table('Branch', [
		'id integer primary key'
		'repo_id integer default 0'
		'name text default ""'
		'author text default ""'
		'hash text default ""'
		'date integer default 0'
		'UNIQUE(repo_id, name)'
	])
	app.create_table('Visit', [
		'id integer primary key'
		'repo_id integer default 0'
		"url text default ''"
		"referer text default ''"
		'created_at integer default 0'
	])
	app.create_table('GitlySettings', [
		'id integer primary key'
		'oauth_client_id text default ""'
		'oauth_client_secret text default ""'
		'only_gh_login int default 1'
		'repo_storage_path text default "./repos"'
	])
	app.create_table('Token', [
		'id integer primary key'
		'user_id integer default 0'
		"value text defaut ''"
		'ip text default ""'
	])
	app.create_table('Token2', [
		'id integer primary key'
		'user_id integer default 0'
		"value text defaut ''"
		'ip text default ""'
	])
	app.create_table('SecurityLog', [
		'id integer primary key'
		'user_id integer default 0'
		"kind int default 0"
		"ip text default ''"
		"arg1 text default ''"
		"arg2 text default ''"
		"created_at int default (strftime('%s', 'now'))"
	])
}

fn (app &App) update_repo_in_db(repo &Repo) {
	id := repo.id
	desc := repo.description
	nr_views := repo.nr_views
	webhook_secret := repo.webhook_secret
	nr_tags := repo.nr_tags
	nr_open_issues := repo.nr_open_issues
	nr_open_prs := repo.nr_open_prs
	nr_branches := repo.nr_branches
	nr_releases := repo.nr_releases
	nr_contributors := repo.nr_contributors
	nr_commits := repo.nr_commits
	sql app.db {
		update Repo set description = desc, nr_views = nr_views, webhook_secret = webhook_secret, nr_tags = nr_tags, nr_open_issues = nr_open_issues, nr_open_prs = nr_open_prs, nr_releases = nr_releases, nr_contributors = nr_contributors, nr_commits = nr_commits, nr_branches = nr_branches where id == id
	}
}

fn (app &App) find_repo_by_name(user int, name string) ?Repo {
	x := sql app.db {
		select from Repo where name == name && user_id == user limit 1
	}
	if x.id == 0 {
		return none
	}
	return x
}

fn (app &App) nr_user_repos(user_id int) int {
	return sql app.db {
		select count from Repo where user_id == user_id
	}
}

fn (app &App) find_user_repos(user_id int) []Repo {
	return sql app.db {
		select from Repo where user_id == user_id
	}
}

fn (app &App) find_repo_by_id(repo_id int) Repo {
	return sql app.db {
		select from Repo where id == repo_id
	}
}

fn (app &App) find_repo(user, name string) bool {
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

fn (app &App) retrieve_repo(id int) Repo {
	return app.repo
}

fn (mut app App) inc_repo_views(repo_id int) {
	sql app.db {
		update Repo set nr_views=nr_views+1 where id == repo_id
	}
}

fn (mut app App) inc_file_views(file_id int) {
	sql app.db {
		update File set nr_views=nr_views+1 where id == file_id
	}
}

fn (mut app App) inc_repo_issues(repo_id int) {
	sql app.db {
		update Repo set nr_open_issues=nr_open_issues+1 where id==repo_id
	}
	app.repo.nr_open_issues++
}

fn (mut app App) update_repo_nr_commits(repo_id, nr_commits int) {
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

fn (mut app App) update_repo_nr_contributor(repo_id, nr_contributors int) {
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

fn (mut app App) delete_repo(id int, path string) {
	// Remove repo
	sql app.db {
		delete from Repo where id == id
	}
	app.info('Removed repo entry ($id)')

	// Remove all commits
	sql app.db {
		delete from Commit where repo_id == id
	}
	app.info('Removed repo commits ($id)')

	// Remove all issues & prs
	app.delete_repo_issues(id)
	app.info('Removed repo issues ($id)')

	// Remove all branches
	app.delete_repo_branches(id)
	app.info('Removed repo branches ($id)')

	// Remove all releases
	app.delete_repo_releases(id)
	app.info('Removed repo releases ($id)')

	// Remove all files
	app.delete_repo_files(id)
	app.info('Removed repo files ($id)')

	// Remove physical files
	app.delete_repo_folder(path)
	app.info('Removed repo folder ($id)')
}
