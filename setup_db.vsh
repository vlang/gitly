#!/usr/bin/env -S v run

import os

const default_db_name = 'gitly'
const default_ci_db_name = 'gitly_ci'
const default_role_name = 'gitly'
const default_role_password = 'gitly'
const default_admin_db = 'postgres'

struct Options {
mut:
	db_name       string = default_db_name
	role_name     string = default_role_name
	role_password string = default_role_password
	admin_db      string = default_admin_db
	with_ci       bool
}

fn main() {
	mut opts := Options{
		db_name:       env_or('GITLY_DB_NAME', default_db_name)
		role_name:     env_or('GITLY_DB_USER', default_role_name)
		role_password: env_or('GITLY_DB_PASSWORD', default_role_password)
		admin_db:      env_or('GITLY_SETUP_ADMIN_DB', default_admin_db)
		with_ci:       env_bool('GITLY_SETUP_WITH_CI')
	}
	args := os.args[1..]
	if '--help' in args || '-h' in args {
		print_help()
		return
	}
	parse_args(mut opts, args)

	psql := os.find_abs_path_of_executable('psql') or {
		fail('`psql` was not found in PATH. Install PostgreSQL client tools first.')
		return
	}

	check_admin_connection(psql, opts.admin_db) or {
		fail('Could not connect to PostgreSQL admin database `${opts.admin_db}`.\n${err.msg()}\nUse PGHOST/PGPORT/PGUSER/PGPASSWORD to point the script at an admin connection.')
		return
	}

	println('Using admin database `${opts.admin_db}`.')
	println('Ensuring role `${opts.role_name}` and database `${opts.db_name}` exist.')
	ensure_role(psql, opts.admin_db, opts.role_name, opts.role_password) or {
		fail(err.msg())
		return
	}
	ensure_database(psql, opts.admin_db, opts.db_name, opts.role_name) or {
		fail(err.msg())
		return
	}
	if opts.with_ci {
		println('Ensuring CI database `${default_ci_db_name}` exists.')
		ensure_database(psql, opts.admin_db, default_ci_db_name, opts.role_name) or {
			fail(err.msg())
			return
		}
	}

	println('')
	println('PostgreSQL setup complete.')
	println('Next step: ./gitly')
	println('gitly will create its tables automatically on first start.')
	if opts.with_ci {
		println('Optional CI service: v run gitly_ci')
	}
}

fn print_help() {
	println('Usage: v run setup_db.vsh [options]')
	println('')
	println('Creates the PostgreSQL role/database that gitly expects on first run.')
	println('Defaults:')
	println('  database: ${default_db_name}')
	println('  role:     ${default_role_name}')
	println('  password: ${default_role_password}')
	println('  admin db: ${default_admin_db}')
	println('')
	println('Options:')
	println('  --db-name=<name>        Database name to create. Default: ${default_db_name}')
	println('  --role=<name>           Role name to create/update. Default: ${default_role_name}')
	println('  --password=<value>      Role password to set. Default: ${default_role_password}')
	println('  --admin-db=<name>       Admin database to connect to. Default: ${default_admin_db}')
	println('  --with-ci               Also create the `${default_ci_db_name}` database for gitly_ci')
	println('')
	println('Connection settings are taken from the normal PostgreSQL env vars:')
	println('  PGHOST PGPORT PGUSER PGPASSWORD')
	println('')
	println('Optional env overrides:')
	println('  GITLY_DB_NAME GITLY_DB_USER GITLY_DB_PASSWORD GITLY_SETUP_ADMIN_DB GITLY_SETUP_WITH_CI')
}

fn parse_args(mut opts Options, args []string) {
	for arg in args {
		if arg == '--with-ci' {
			opts.with_ci = true
			continue
		}
		if arg.starts_with('--db-name=') {
			opts.db_name = arg.all_after('--db-name=')
			continue
		}
		if arg.starts_with('--role=') {
			opts.role_name = arg.all_after('--role=')
			continue
		}
		if arg.starts_with('--password=') {
			opts.role_password = arg.all_after('--password=')
			continue
		}
		if arg.starts_with('--admin-db=') {
			opts.admin_db = arg.all_after('--admin-db=')
			continue
		}
		fail('Unknown argument: ${arg}\nRun `v run setup_db.vsh --help` for usage.')
	}
}

fn env_or(key string, fallback string) string {
	if value := os.getenv_opt(key) {
		if value != '' {
			return value
		}
	}
	return fallback
}

fn env_bool(key string) bool {
	value := os.getenv(key).trim_space().to_lower()
	return value in ['1', 'true', 'yes', 'on']
}

fn check_admin_connection(psql string, admin_db string) ! {
	_ = psql_query(psql, admin_db, 'select 1;')!
}

fn ensure_role(psql string, admin_db string, role_name string, password string) ! {
	if role_exists(psql, admin_db, role_name)! {
		psql_exec(psql, admin_db,
			'alter role ${sql_ident(role_name)} with login password ${sql_literal(password)};')!
		println('Updated role `${role_name}`.')
		return
	}
	psql_exec(psql, admin_db,
		'create role ${sql_ident(role_name)} with login password ${sql_literal(password)};')!
	println('Created role `${role_name}`.')
}

fn ensure_database(psql string, admin_db string, db_name string, role_name string) ! {
	if database_exists(psql, admin_db, db_name)! {
		println('Database `${db_name}` already exists.')
	} else {
		psql_exec(psql, admin_db,
			'create database ${sql_ident(db_name)} owner ${sql_ident(role_name)};')!
		println('Created database `${db_name}`.')
	}
	psql_exec(psql, admin_db,
		'alter database ${sql_ident(db_name)} owner to ${sql_ident(role_name)};')!
	psql_exec(psql, admin_db,
		'grant all privileges on database ${sql_ident(db_name)} to ${sql_ident(role_name)};')!
	psql_exec(psql, db_name, 'alter schema public owner to ${sql_ident(role_name)};')!
	psql_exec(psql, db_name, 'grant all on schema public to ${sql_ident(role_name)};')!
}

fn role_exists(psql string, admin_db string, role_name string) !bool {
	result := psql_query(psql, admin_db,
		'select 1 from pg_roles where rolname = ${sql_literal(role_name)};')!
	return result == '1'
}

fn database_exists(psql string, admin_db string, db_name string) !bool {
	result := psql_query(psql, admin_db,
		'select 1 from pg_database where datname = ${sql_literal(db_name)};')!
	return result == '1'
}

fn psql_query(psql string, database string, query string) !string {
	cmd := '${os.quoted_path(psql)} -X -v ON_ERROR_STOP=1 -d ${os.quoted_path(database)} -tAc ${os.quoted_path(query)}'
	res := os.execute(cmd)
	if res.exit_code != 0 {
		return error(res.output.trim_space())
	}
	return res.output.trim_space()
}

fn psql_exec(psql string, database string, query string) ! {
	cmd := '${os.quoted_path(psql)} -X -v ON_ERROR_STOP=1 -d ${os.quoted_path(database)} -c ${os.quoted_path(query)}'
	res := os.execute(cmd)
	if res.exit_code != 0 {
		return error(res.output.trim_space())
	}
}

fn sql_literal(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn sql_ident(value string) string {
	return '"' + value.replace('"', '""') + '"'
}

fn fail(message string) {
	eprintln(message)
	exit(1)
}
