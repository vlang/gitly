// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

pub fn (mut app App) get_all_repo_tags(repo_id int) []Tag {
	return sql app.db {
		select from Tag where repo_id == repo_id order by date desc
	}
}
