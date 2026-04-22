module config

import os
import json

pub struct Config {
pub:
	repo_storage_path string
	archive_path      string
	avatars_path      string
	hostname          string
	ci_service_url    string
	port              int
}

pub fn read_config(path string) !Config {
	config_raw := os.read_file(path)!

	return json.decode(Config, config_raw)!
}
