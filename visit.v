// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Visit {
	id         int    [primary; sql: serial]
	repo_id    int
	url        string
	referer    string
	created_at int
}

fn (mut app App) add_visit() {
	visit := Visit{
		repo_id: app.repo.id
		url: app.req.url
		referer: app.req.referer()
		created_at: int(time.now().unix)
	}
	sql app.db {
		insert visit into Visit
	}
}
