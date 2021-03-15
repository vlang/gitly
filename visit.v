// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import vweb

struct Visit {
	id         int
	repo_id    int
	url        string
	referer    string
	created_at int
}

fn (mut app App) add_visit(mut c vweb.Context) {
	mut sess := app.get_session(mut c)
	visit := Visit{
		repo_id: sess.repo.id
		url: c.req.url
		referer: c.req.referer()
		created_at: int(time.now().unix)
	}
	sql app.db {
		insert visit into Visit
	}
}
