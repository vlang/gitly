// Copyright (c) 2020-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

struct GitlySettings {
	id int [primary; sql: serial]
mut:
	oauth_client_id     string
	oauth_client_secret string
	repo_storage_path   string = './repos'
	archive_path        string = './archives'
	hostname            string = 'gitly.org'
}
