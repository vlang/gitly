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
	nr_topics          int       [skip]
	nr_views           int
	latest_update_hash string    [skip]
	latest_activity    time.Time [skip]
mut:
	webhook_secret  string
	nr_tags         int
	nr_open_issues  int
	nr_open_prs     int
	nr_releases     int
	nr_branches     int
	lang_stats      []LangStat        [skip]
	created_at      int
	nr_contributors int
	nr_commits      int
	labels          []Label           [skip]
	status          RepoStatus        [skip]
	msg_cache       map[string]string [skip]
}
