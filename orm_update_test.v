module main

import config
import git
import os

// Coverage for the ORM update helpers in repo/branch.v (update_branch) and
// repo/repo.v (save_repo). Both build `update X set col = col` statements where
// the local variable shadows the column name, so the compiler has to pick one.
// A silent self-assignment would make every save a no-op without failing
// anything else.
//
// Nothing else catches this. The branch row is written by the push path and the
// repo row by save_repo, so a self-assignment would surface only as stale numbers
// in the UI, long after the write appeared to succeed.

fn orm_fixture_git(args []string) string {
	result := git.Git.exec(args)
	if result.exit_code != 0 {
		panic('git ${args} failed: ${result.output}')
	}
	return result.output.trim_space()
}

fn orm_fixture_app(root string) !App {
	work_dir := os.join_path(root, 'work')
	bare_dir := os.join_path(root, 'project.git')
	orm_fixture_git(['init', '-b', 'main', work_dir])
	orm_fixture_git(['-C', work_dir, 'config', 'user.name', 'Owner'])
	orm_fixture_git(['-C', work_dir, 'config', 'user.email', 'owner@example.com'])
	os.write_file(os.join_path(work_dir, 'README.md'), 'hello\n')!
	orm_fixture_git(['-C', work_dir, 'add', 'README.md'])
	orm_fixture_git(['-C', work_dir, 'commit', '-m', 'initial'])
	orm_fixture_git(['clone', '--bare', work_dir, bare_dir])

	conf := config.Config{
		repo_storage_path: root
		archive_path:      root
		avatars_path:      root
		sqlite:            config.SqliteConfig{
			path: os.join_path(root, 'test.sqlite')
		}
	}
	mut app := App{
		db:     connect_db(conf)!
		config: conf
	}
	app.create_tables()!
	user := User{
		id:            1
		username:      'owner'
		is_registered: true
	}
	sql app.db {
		insert user into User
	}!
	app.add_repo(Repo{
		id:             1
		git_dir:        bare_dir
		name:           'project'
		user_id:        1
		user_name:      'owner'
		description:    'seeded description'
		is_public:      true
		primary_branch: 'main'
		status:         .done
	})!
	return app
}

fn test_update_branch_writes_new_values() ! {
	$if !sqlite ? {
		return
	}
	root := os.join_path(os.temp_dir(), 'gitly_orm_update_branch_${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root)!
	defer {
		os.rmdir_all(root) or {}
	}
	mut app := orm_fixture_app(root)!
	defer {
		app.db.close() or {}
	}

	// If `update Branch set author = author` binds the right-hand side to the
	// column rather than the local variable, this is a self-assignment and the
	// row keeps its seeded values forever.
	seeded := Branch{
		id:      1
		repo_id: 1
		name:    'main'
		author:  'old_author'
		hash:    'old_hash'
		date:    1000
	}
	sql app.db {
		insert seeded into Branch
	}!
	second_branch := Branch{
		id:      2
		repo_id: 1
		name:    'other'
		author:  'other_author'
		hash:    'other_hash'
		date:    500
	}
	sql app.db {
		insert second_branch into Branch
	}!
	app.update_branch(1, 'new_author', 'new_hash', 2000)!

	branch := app.find_repo_branch_by_name(1, 'main')
	assert branch.author == 'new_author'
	assert branch.hash == 'new_hash'
	assert branch.date == 2000
	other := app.find_repo_branch_by_name(1, 'other')
	assert other.author == 'other_author'
	assert other.hash == 'other_hash'
	assert other.date == 500
}

fn test_save_repo_writes_updated_counters() ! {
	$if !sqlite ? {
		return
	}
	root := os.join_path(os.temp_dir(), 'gitly_orm_save_repo_${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root)!
	defer {
		os.rmdir_all(root) or {}
	}
	mut app := orm_fixture_app(root)!
	defer {
		app.db.close() or {}
	}

	// Insert a second repository so a tautological where id == id (which
	// would update every row) is detected instead of silently passing.
	second := Repo{
		id:             2
		git_dir:        (app.find_repo_by_id(1) or { panic('repo missing') }).git_dir
		name:           'other'
		user_id:        1
		user_name:      'owner'
		description:    'second repo description'
		is_public:      false
		primary_branch: 'main'
		status:         .done
		nr_branches:    1
		nr_tags:        2
		nr_stars:       3
	}
	sql app.db {
		insert second into Repo
	}!

	// Construct a brand-new Repo value (rather than mutating a retrieved one)
	// so the shadowed `description`, `views_count` and `is_public` assignments
	// in save_repo are actually exercised.
	repo := Repo{
		id:             1
		git_dir:        (app.find_repo_by_id(1) or { panic('repo missing') }).git_dir
		name:           'project'
		user_id:        1
		user_name:      'owner'
		description:    'updated description'
		is_public:      false
		primary_branch: 'main'
		status:         .done
		views_count:    42
		nr_branches:    7
		nr_tags:        11
		nr_stars:       13
		nr_releases:    5
		webhook_secret: 'rotated-secret'
	}
	app.save_repo(repo)!

	saved := app.find_repo_by_id(1) or { return error('repo missing') }
	assert saved.description == 'updated description'
	assert saved.is_public == false
	assert saved.views_count == 42
	assert saved.nr_branches == 7
	assert saved.nr_tags == 11
	assert saved.nr_stars == 13
	assert saved.nr_releases == 5
	assert saved.webhook_secret == 'rotated-secret'

	// The second repository must be untouched.
	other := app.find_repo_by_id(2) or { return error('repo missing') }
	assert other.description == 'second repo description'
	assert other.is_public == false
	assert other.views_count == 0
	assert other.nr_branches == 1
	assert other.nr_tags == 2
	assert other.nr_stars == 3
}
