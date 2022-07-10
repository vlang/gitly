module main

import time

struct Repo {
	id                 int       [primary; sql: serial]
	git_dir            string
	name               string
	user_id            int
	user_name          string
	clone_url          string    [skip]
	primary_branch     string
	description        string
	is_public          bool
	users_contributed  []string  [skip]
	users_authorized   []string  [skip]
	topics_count       int       [skip]
	views_count        int
	latest_update_hash string    [skip]
	latest_activity    time.Time [skip]
mut:
	webhook_secret     string
	tags_count         int
	open_issues_count  int
	open_prs_count     int
	releases_count     int
	branches_count     int
	lang_stats         []LangStat        [skip]
	created_at         int
	contributors_count int
	labels             []Label           [skip]
	status             RepoStatus        [skip]
	msg_cache          map[string]string [skip]
}
