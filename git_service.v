module main

import strings
import git

enum GitService {
	receive
	upload
	unknown
}

fn (g GitService) str() string {
	return match g {
		.receive { 'receive-pack' }
		.upload { 'upload-pack' }
		else { 'unknown' }
	}
}

fn extract_service_from_url(url string) GitService {
	// Get service type from the git request.
	// Receive (git push) or upload	(git pull)
	return if url.contains('service=git-upload-pack') {
		GitService.upload
	} else if url.contains('service=git-receive-pack') {
		GitService.receive
	} else {
		GitService.unknown
	}
}

fn build_git_service_response(service GitService, body string) string {
	mut git_response := strings.new_builder(100)
	git_response.write_string(git.write_packet('# service=git-$service\n'))
	git_response.write_string(git.flush_packet())
	git_response.write_string(body)

	return git_response.str()
}
