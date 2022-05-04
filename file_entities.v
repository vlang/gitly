// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

struct File {
	id                 int    [primary; sql: serial]
	repo_id            int    [unique: 'file']
	name               string [unique: 'file']
	parent_path        string [unique: 'file']
	is_dir             bool
	branch             string [unique: 'file']
	contributors_count int
	last_hash          string
	size               int
	views_count        int
mut:
	last_msg  string
	last_time int
	commit    Commit [skip]
}
