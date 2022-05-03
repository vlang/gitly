// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

fn (mut app App) add_visit(repo_id int, url string, referer string) {
	visit := Visit{
		repo_id: repo_id
		url: url
		referer: referer
		created_at: int(time.now().unix)
	}

	sql app.db {
		insert visit into Visit
	}
}
