// Copyright (c) 2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

struct GitlySettings {
	id                  int
	oauth_client_id     string
	oauth_client_secret string
	only_gh_login       bool = true
}
