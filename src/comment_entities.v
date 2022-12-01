// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

struct Comment {
mut:
	id         int    [primary; sql: serial]
	author_id  int
	issue_id   int
	created_at int
	text       string
}
