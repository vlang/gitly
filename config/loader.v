module config

import os
import x.json2 as json

pub struct Config {
pub:
	repo_storage_path string
	archive_path      string
	avatars_path      string
	hostname          string
	ci_service_url    string
	port              int
	pg                PgConfig
	sqlite            SqliteConfig
}

pub struct PgConfig {
pub:
	host     string = 'localhost'
	port     int    = 5432
	dbname   string = 'gitly'
	user     string = 'gitly'
	password string = 'gitly'
	conninfo string
}

pub struct SqliteConfig {
pub:
	path string = 'gitly.sqlite'
}

pub fn read_config(path string) !Config {
	config_raw := os.read_file(path)!

	return json.decode[Config](config_raw)!
}
