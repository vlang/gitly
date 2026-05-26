module main

import config
import db.sqlite
import os

type GitlyDb = sqlite.DB

fn connect_db(conf config.Config) !GitlyDb {
	path := first_env(['GITLY_SQLITE_PATH', 'GITLY_DB_PATH'], conf.sqlite.path)
	mut db := sqlite.connect(path)!
	if db.busy_timeout(10000) != 0 {
		return error('failed to configure sqlite busy timeout')
	}
	db.exec('pragma journal_mode = WAL;') or { eprintln('cannot enable sqlite WAL mode: ${err}') }
	return GitlyDb(db)
}

fn db_backend_name() string {
	return 'sqlite'
}

fn db_exec_values(mut db GitlyDb, query string) ![][]string {
	rows := db.exec(query)!
	mut values := [][]string{cap: rows.len}
	for row in rows {
		values << row.vals.clone()
	}
	return values
}

fn db_last_insert_id(mut db GitlyDb) int {
	rows := db.exec('select last_insert_rowid()') or { return 0 }
	if rows.len > 0 && rows[0].vals.len > 0 {
		return rows[0].vals[0].int()
	}
	return 0
}

fn db_column_exists(mut db GitlyDb, table_name string, column_name string) !bool {
	rows := db_exec_values(mut db, 'pragma table_info(${sql_table(table_name)})')!
	for row in rows {
		if row.len > 1 && row[1] == column_name {
			return true
		}
	}
	return false
}

fn db_bool_column_type() string {
	return 'INTEGER NOT NULL DEFAULT 0'
}

fn first_env(keys []string, fallback string) string {
	for key in keys {
		value := os.getenv(key)
		if value != '' {
			return value
		}
	}
	return fallback
}
