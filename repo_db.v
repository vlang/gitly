// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

fn (mut app App) create_table(name string, fields []string) {
	app.db.exec('create table `$name` (' + fields.join(',') + ')')
}

fn (mut app App) create_tables() {
	app.create_table('Repo', [
		'id integer primary key'
		"git_dir text default ''"
		"name text default ''"
		"description text default ''"
		'user_id int default 0'
		'nr_views int default 0'
		'nr_commits int default 0'
		'nr_open_issues int default 0'
		'nr_tags int default 0'
		'nr_releases int default 0'
		'nr_open_prs int default 0'
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
		'UNIQUE(parent_path, name, repo_id) ON CONFLICT REPLACE'
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
		'UNIQUE(hash)'
	])
	// author text default '' is to to avoid joins
	app.create_table('LangStat', [
		'id int default 0'
		'repo_id int default 0'
		'name text default ""'
		'nr_lines int default 0'
		'pct int default 0'
		'color text default ""'
	])
	app.create_table('User', [
		'id integer primary key'
		'name text default ""'
		'username text default ""'
		'password text default ""'
		'token text default ""'
		'avatar text default ""'
		'nr_posts integer default 0'
		'is_github int default 0'
		'is_registered int default 0'
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
}

fn (app &App) find_repo_by_name(name string) ?Repo {
	x := sql app.db {
		select from Repo where name == name
	}
	if x.len == 0 {
		return none
	}
	return x[0]
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
