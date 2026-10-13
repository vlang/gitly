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
	app.update_branch(1, 'new_author', 'new_hash', 2000)!

	branch := app.find_repo_branch_by_name(1, 'main')
	assert branch.author == 'new_author'
	assert branch.hash == 'new_hash'
	assert branch.date == 2000
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

	// Only the mutable fields of Repo are set here. `description`, `is_public` and
	// `views_count` are outside the `mut:` block, so save_repo cannot change them
	// on a row read back from the database, and asserting on them would fail for
	// that reason rather than because of the ORM update.
	mut repo := app.find_repo_by_id(1)!
	repo.nr_branches = 7
	repo.nr_tags = 11
	repo.nr_stars = 13
	repo.nr_releases = 5
	repo.webhook_secret = 'rotated-secret'
	app.save_repo(repo)!

	saved := app.find_repo_by_id(1)!
	assert saved.nr_branches == 7
	assert saved.nr_tags == 11
	assert saved.nr_stars == 13
	assert saved.nr_releases == 5
	assert saved.webhook_secret == 'rotated-secret'
}
