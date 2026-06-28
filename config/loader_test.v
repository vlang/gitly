module config

import os

fn test_read_config_uses_database_defaults() {
	path := os.join_path(os.temp_dir(), 'gitly_config_defaults_${os.getpid()}.json')
	os.write_file(path,
		'{"repo_storage_path":"./repos","archive_path":"./archives","avatars_path":"./avatars","hostname":"gitly.test","ci_service_url":"http://localhost:8081"}')!
	defer {
		os.rm(path) or {}
	}

	conf := read_config(path)!

	assert conf.pg.host == 'localhost'
	assert conf.pg.port == 5432
	assert conf.pg.dbname == 'gitly'
	assert conf.pg.user == 'gitly'
	assert conf.pg.password == 'gitly'
	assert conf.sqlite.path == 'gitly.sqlite'
	assert conf.usdt_wallet == ''
}
