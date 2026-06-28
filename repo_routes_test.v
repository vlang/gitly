module main

import os
import git

fn test_read_clone_progress_hides_initial_bare_clone_message() {
	progress_path := os.join_path(os.temp_dir(), 'gitly_clone_progress_${os.getpid()}.log')
	os.write_file(progress_path,
		"Cloning into bare repository './repos/medvednikov/v4'...\nremote: Enumerating objects: 251249, done.\nReceiving objects:  31% (78861/251249), 54.49 MiB | 3.59 MiB/s")!
	defer {
		os.rm(progress_path) or {}
	}

	assert read_clone_progress(progress_path) == 'remote: Enumerating objects: 251249, done.\nReceiving objects:  31% (78861/251249), 54.49 MiB | 3.59 MiB/s'
}

fn test_clone_size_limit_marker_is_detected_and_hidden_from_progress() {
	progress_path := os.join_path(os.temp_dir(), 'gitly_clone_size_limit_${os.getpid()}.log')
	os.write_file(progress_path,
		'Receiving objects: 100% (10/10), 100.00 MiB | 2.00 MiB/s\n${git.clone_size_limit_marker}\n')!
	defer {
		os.rm(progress_path) or {}
	}

	assert clone_size_limit_failed(progress_path)
	assert read_clone_progress(progress_path) == 'Receiving objects: 100% (10/10), 100.00 MiB | 2.00 MiB/s'
}

fn test_clone_size_limit_is_only_for_non_admin_not_self_hosted_instances() {
	assert should_enforce_clone_size_limit(false, true)
	assert !should_enforce_clone_size_limit(true, true)
	assert !should_enforce_clone_size_limit(false, false)
	assert !should_enforce_clone_size_limit(true, false)
}
