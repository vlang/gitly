module git

import net.http

pub fn check_git_repo_url(url string) bool {
	repo_url := remove_git_extension_if_exists(url)
	refs_url := '$repo_url/info/refs?service=git-upload-pack'
	mut headers := http.new_header()

	headers.add_custom('User-Agent', 'git/2.30.0') or {}
	headers.add_custom('Git-Protocol', 'version=2') or {}

	config := http.FetchConfig{
		url: refs_url
		header: headers
	}

	response := http.fetch(config) or { return false }

	if response.status_code != 200 {
		return false
	}

	return response.body.contains('service=git-upload-pack')
}
