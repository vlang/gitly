// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

struct Branch {
mut:
	id      int    [primary; sql: serial]
	repo_id int    [unique: 'branch']
	name    string [unique: 'branch']
	author  string // author of latest commit on branch
	hash    string // hash of latest commit on branch
	date    int    // time of latest commit on branch
}
