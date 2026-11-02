module main

import crypto.sha256
import crypto.bcrypt
import time
import os
import validation

// bcrypt_cost is the work factor for password hashing. 12 is a good balance of
// security and speed on current hardware.
const bcrypt_cost = 12

struct User {
	id              int @[primary; sql: serial]
	full_name       string
	username        string @[unique]
	github_username string
	github_id       i64
	password        string
	salt            string
	created_at      time.Time
	is_github       bool
	is_registered   bool
	is_blocked      bool
	is_admin        bool
	oauth_state     string @[skip]

	// for github oauth XSRF protection
mut:
	namechanges_count               int
	last_namechange_time            int
	posts_count                     int
	last_post_time                  int
	avatar                          string
	emails                          []Email @[skip]
	login_attempts                  int
	login_attempt_window_started_at i64
	login_throttled_until           i64
	is_bootstrap_admin              bool
}

struct Email {
	id      int @[primary; sql: serial]
	user_id int
	email   string @[unique]
}

struct Contributor {
	id      int @[primary; sql: serial]
	user_id int @[unique: 'contributor']
	repo_id int @[unique: 'contributor']
}

pub fn (mut app App) set_user_block_status(user_id int, status bool) ! {
	sql app.db {
		update User set is_blocked = status where id == user_id
	}!
}

pub fn (mut app App) set_user_admin_status(user_id int, status bool) ! {
	sql app.db {
		update User set is_admin = status where id == user_id
	}!
}

// claim_bootstrap_administrator atomically promotes one registered user on a
// fresh installation. The partial unique index created by migrate_tables is
// the final arbiter when registrations race: at most one UPDATE can set the
// bootstrap marker, while is_admin itself remains unconstrained for admins
// added later through normal administration.
fn (mut app App) claim_bootstrap_administrator(user_id int) !bool {
	if user_id <= 0 {
		return false
	}
	rows := db_exec_values(mut app.db, 'update ${sql_table('User')} set\n\t\t${sql_table('is_admin')} = true,\n\t\t${sql_table('is_bootstrap_admin')} = true\n\t\twhere ${sql_table('id')} = ${user_id}\n\t\t\tand ${sql_table('is_registered')} is true\n\t\t\tand not exists (\n\t\t\t\tselect 1 from ${sql_table('User')}\n\t\t\t\twhere ${sql_table('is_bootstrap_admin')} is true\n\t\t\t)\n\t\treturning ${sql_table('id')}') or {
		// PostgreSQL can let two statements reach the unique index together;
		// the loser is an expected non-claim, not a registration failure.
		if is_unique_constraint_error(err) {
			return false
		}
		return err
	}
	return rows.len == 1 && rows[0].len == 1 && rows[0][0].int() == user_id
}

// hash_password_with_salt returns a bcrypt hash of the password. bcrypt
// generates and embeds its own random salt with a tunable cost factor, so the
// `salt` argument is ignored for new hashes (kept only so existing callers and
// the User.salt column are unaffected).
fn hash_password_with_salt(password string, _salt string) string {
	return bcrypt.generate_from_password(password.bytes(), bcrypt_cost) or { '' }
}

// compare_password_with_hash verifies a password against a stored hash. It
// accepts both new bcrypt hashes ($2...) and legacy salted-SHA-256 hashes, so
// users created before the bcrypt migration can still log in; their hash is
// upgraded to bcrypt on next login (see maybe_upgrade_password_hash).
fn compare_password_with_hash(password string, salt string, hashed string) bool {
	if password_hash_is_legacy(hashed) {
		legacy := sha256.sum('${password}${salt}'.bytes()).hex()
		return legacy == hashed
	}
	bcrypt.compare_hash_and_password(password.bytes(), hashed.bytes()) or { return false }
	return true
}

// password_hash_is_legacy reports whether a stored hash uses the old
// salted-SHA-256 scheme (anything that is not a bcrypt `$2...` hash) and should
// be upgraded to bcrypt after a successful login.
fn password_hash_is_legacy(hashed string) bool {
	return !hashed.starts_with('\$2')
}

// maybe_upgrade_password_hash rehashes a legacy password with bcrypt after the
// user has successfully authenticated, so old SHA-256 hashes are phased out
// transparently. The plaintext password is only available at login time.
fn (mut app App) maybe_upgrade_password_hash(user User, password string) {
	if !password_hash_is_legacy(user.password) {
		return
	}
	new_hash := hash_password_with_salt(password, '')
	if new_hash == '' {
		return
	}
	app.update_user_password_hash(user.id, new_hash) or {
		app.info('failed to upgrade password hash for user ${user.id}: ${err}')
	}
}

fn (mut app App) update_user_password_hash(user_id int, hashed string) ! {
	sql app.db {
		update User set password = hashed where id == user_id
	}!
}

pub fn (mut app App) register_user(username string, password string, salt string, emails []string, github bool, is_admin bool) !bool {
	if emails.len == 0 {
		return error('at least one email address is required')
	}
	account_name := username.trim_space().to_lower()
	if !validation.is_username_valid(account_name) || is_reserved_account_name(account_name) {
		return error('username `${account_name}` is not available')
	}

	mut clean_emails := []string{cap: emails.len}
	for raw_email in emails {
		email := raw_email.trim_space().to_lower()
		if !validation.is_email_valid(email) || email in clean_emails {
			return error('email `${email}` is invalid or duplicated')
		}
		clean_emails << email
	}

	// Keep the account row and every address in one pinned transaction. A
	// uniqueness failure on any later email must release the username and roll
	// back emails inserted earlier in this registration.
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}

	orgs := sql tx {
		select from Org where name == account_name limit 1
	}!
	if orgs.len > 0 {
		return error('username `${account_name}` is already taken')
	}

	username_users := sql tx {
		select from User where username == account_name limit 1
	}!
	username_user := if username_users.len == 1 { username_users[0] } else { User{} }
	if username_user.id != 0 && username_user.is_registered {
		return error('username `${account_name}` is already taken')
	}
	if username_user.id != 0 && !github {
		return error('username `${account_name}` is already taken')
	}

	for email in clean_emails {
		candidate_email := email
		matching_emails := sql tx {
			select from Email where email == candidate_email limit 1
		}!
		if matching_emails.len == 1 {
			if matching_emails[0].user_id != username_user.id {
				return error('email `${email}` is already in use')
			}
		}
	}

	// GitHub imports create unregistered shadow users. OAuth is allowed to
	// upgrade only that exact shadow row; it must never attach a GitHub handle
	// to an existing password account with the same name.
	if username_user.id != 0 {
		for email in clean_emails {
			candidate_email := email
			matching_emails := sql tx {
				select from Email where email == candidate_email limit 1
			}!
			if matching_emails.len == 0 {
				user_email := Email{
					user_id: username_user.id
					email:   candidate_email
				}
				sql tx {
					insert user_email into Email
				} or {
					if is_unique_constraint_error(err) {
						return error('email `${candidate_email}` is already in use')
					}
					return err
				}
			}
		}
		id := username_user.id
		sql tx {
			update User set is_registered = true, is_github = true, github_username = account_name
			where id == id
		}!
		tx.commit()!
		committed = true
		app.add_activity(id, 'joined') or { app.info('could not record joined activity') }
		app.create_user_dir(account_name)
		return true
	}

	user := User{
		username:        account_name
		password:        password
		salt:            salt
		created_at:      time.now()
		is_registered:   true
		is_github:       github
		github_username: if github { account_name } else { '' }
		avatar:          default_avatar_name
		is_admin:        is_admin
	}

	sql tx {
		insert user into User
	} or {
		if is_unique_constraint_error(err) {
			return error('username `${account_name}` or email `${clean_emails[0]}` is already in use')
		}
		return err
	}

	created_users := sql tx {
		select from User where username == account_name limit 1
	}!
	if created_users.len != 1 {
		return error('user `${account_name}` was not found after insert')
	}
	created := created_users[0]
	for email in clean_emails {
		user_email := Email{
			user_id: created.id
			email:   email
		}
		sql tx {
			insert user_email into Email
		} or {
			if is_unique_constraint_error(err) {
				return error('email `${email}` is already in use')
			}
			return err
		}
	}
	tx.commit()!
	committed = true
	app.add_activity(created.id, 'joined') or {
		app.info('could not record joined activity: ${err}')
	}
	app.create_user_dir(account_name)

	return true
}

fn is_unique_constraint_error(err IError) bool {
	return err.msg().to_lower().contains('unique constraint')
}

pub fn (app App) email_exists(value string) bool {
	rows := sql app.db {
		select from Email where email == value limit 1
	} or { [] }
	return rows.len > 0
}

fn (mut app App) create_user_dir(username string) {
	user_path := '${app.config.repo_storage_path}/${username}'

	os.mkdir(user_path) or {
		app.info('Failed to create ${user_path}')
		app.info('Error: ${err}')
		return
	}
}

pub fn (mut app App) update_user_avatar(user_id int, filename_or_url string) ! {
	sql app.db {
		update User set avatar = filename_or_url where id == user_id
	}!
}

pub fn (mut app App) add_user(user User) ! {
	sql app.db {
		insert user into User
	}!
}

pub fn (mut app App) add_email(user_id int, email string) ! {
	user_email := Email{
		user_id: user_id
		email:   email
	}

	sql app.db {
		insert user_email into Email
	}!
}

pub fn (mut app App) add_contributor(user_id int, repo_id int) ! {
	if !app.contains_contributor(user_id, repo_id) {
		contributor := Contributor{
			user_id: user_id
			repo_id: repo_id
		}

		sql app.db {
			insert contributor into Contributor
		}!
	}
}

pub fn (app App) get_username_by_id(id int) ?string {
	users := sql app.db {
		select from User where id == id limit 1
	} or { [] }

	if users.len == 0 {
		return none
	}

	return users.first().username
}

pub fn (app App) get_user_by_username(value string) ?User {
	users := sql app.db {
		select from User where username == value limit 1
	} or { [] }

	if users.len == 0 {
		return none
	}

	mut user := users.first()
	emails := app.find_user_emails(user.id)
	user.emails = emails

	return user
}

pub fn (app App) get_user_by_id(id int) ?User {
	users := sql app.db {
		select from User where id == id
	} or { [] }

	if users.len == 0 {
		return none
	}

	mut user := users.first()
	emails := app.find_user_emails(user.id)
	user.emails = emails

	return user
}

pub fn (mut app App) get_user_by_github_username(name string) ?User {
	users := sql app.db {
		select from User where github_username == name limit 1
	} or { [] }

	if users.len == 0 {
		return none
	}

	mut user := users.first()
	emails := app.find_user_emails(user.id)
	user.emails = emails

	return user
}

pub fn (mut app App) get_user_by_github_id(github_id i64) ?User {
	if github_id <= 0 {
		return none
	}
	users := sql app.db {
		select from User where github_id == github_id limit 1
	} or { [] }

	if users.len == 0 {
		return none
	}

	mut user := users.first()
	user.emails = app.find_user_emails(user.id)
	return user
}

pub fn (mut app App) get_user_by_email(value string) ?User {
	emails := sql app.db {
		select from Email where email == value
	} or { [] }

	if emails.len != 1 {
		return none
	}

	return app.get_user_by_id(emails[0].user_id)
}

pub fn (app App) find_user_emails(user_id int) []Email {
	emails := sql app.db {
		select from Email where user_id == user_id
	} or { [] }

	return emails
}

pub fn (mut app App) find_repo_registered_contributor(id int) []User {
	contributors := sql app.db {
		select from Contributor where repo_id == id
	} or { [] }
	mut users := []User{cap: contributors.len}
	for contributor in contributors {
		user := app.get_user_by_id(contributor.user_id) or { continue }

		users << user
	}
	return users
}

pub fn (mut app App) get_all_registered_users_as_page(offset int) []User {
	// FIXME: 30 -> admin_users_per_page
	mut users := sql app.db {
		select from User where is_registered == true limit 30 offset offset
	} or { [] }
	for i, user in users {
		users[i].emails = app.find_user_emails(user.id)
	}
	return users
}

pub fn (mut app App) get_all_registered_user_count() int {
	return sql app.db {
		select count from User where is_registered == true
	} or { 0 }
}

fn (mut app App) search_users(query string) []User {
	q := 'select id, full_name, username, avatar from ${sql_table('User')} where is_registered is true and is_blocked is false and ' + '(lower(username) like lower(${sql_like_pattern(query)}) or lower(full_name) like lower(${sql_like_pattern(query)})) limit ${search_results_limit}'
	repo_rows := db_exec_values(mut app.db, q) or { return [] }
	mut users := []User{}
	for row in repo_rows {
		users << User{
			id:        row[0].int()
			full_name: row[1]
			username:  row[2]
			avatar:    row[3]
		}
	}
	return users
}

pub fn (mut app App) get_users_count() !int {
	return sql app.db {
		select count from User
	}!
}

pub fn (mut app App) get_count_repo_contributors(id int) !int {
	return sql app.db {
		select count from Contributor where repo_id == id
	} or { 0 }
}

pub fn (mut app App) contains_contributor(user_id int, repo_id int) bool {
	count := sql app.db {
		select count from Contributor where repo_id == repo_id && user_id == user_id
	} or { 0 }
	return count > 0
}

pub fn (mut app App) increment_user_post(mut user User) ! {
	id := user.id
	now := int(time.now().unix())

	if user_post_window_expired(user, now) {
		user.posts_count = 0
		user.last_post_time = now
		sql app.db {
			update User set posts_count = 0, last_post_time = now where id == id
		}!
	}

	user.posts_count++
	sql app.db {
		update User set posts_count = posts_count + 1 where id == id
	}!
}

fn user_post_window_expired(user User, now int) bool {
	return user.last_post_time <= 0 || now >= user.last_post_time + int(24 * time.hour / time.second)
}

fn user_reached_post_limit(user User, now int) bool {
	return !user_post_window_expired(user, now) && user.posts_count >= posts_per_day
}

// record_failed_login advances the persisted per-account throttle in one SQL
// statement. Keeping the calculation in the database prevents simultaneous
// failures from losing increments and means a process restart cannot clear the
// window. Attempts made while throttled do not extend the throttle indefinitely.
pub fn (mut app App) record_failed_login(user_id int, now i64) ! {
	window_cutoff := now - login_attempt_window_seconds
	throttled_until := now + login_throttle_seconds
	app.db.exec('update ${sql_table('User')} set\n\t\t${sql_table('login_attempts')} = case\n\t\t\twhen ${sql_table('login_throttled_until')} > ${now} then ${sql_table('login_attempts')}\n\t\t\twhen ${sql_table('login_attempt_window_started_at')} <= ${window_cutoff} then 1\n\t\t\telse ${sql_table('login_attempts')} + 1\n\t\tend,\n\t\t${sql_table('login_attempt_window_started_at')} = case\n\t\t\twhen ${sql_table('login_throttled_until')} > ${now} then ${sql_table('login_attempt_window_started_at')}\n\t\t\twhen ${sql_table('login_attempt_window_started_at')} <= ${window_cutoff} then ${now}\n\t\t\telse ${sql_table('login_attempt_window_started_at')}\n\t\tend,\n\t\t${sql_table('login_throttled_until')} = case\n\t\t\twhen ${sql_table('login_throttled_until')} > ${now} then ${sql_table('login_throttled_until')}\n\t\t\twhen ${sql_table('login_attempt_window_started_at')} <= ${window_cutoff} then 0\n\t\t\twhen ${sql_table('login_attempts')} + 1 >= ${max_login_attempts} then ${throttled_until}\n\t\t\telse 0\n\t\tend\n\t\twhere ${sql_table('id')} = ${user_id}')!
}

pub fn (mut app App) reset_user_login_throttle(user_id int) ! {
	zero_attempts := 0
	zero_time := i64(0)
	sql app.db {
		update User set login_attempts = zero_attempts, login_attempt_window_started_at = zero_time,
		login_throttled_until = zero_time where id == user_id
	}!
}

fn user_login_is_throttled(user User, now i64) bool {
	return user.login_throttled_until > now
}

pub fn (mut app App) check_user_blocked(user_id int) bool {
	user := app.get_user_by_id(user_id) or { return false }
	return user.is_blocked
}

fn (mut app App) change_username(user_id int, old_username string, username string) ! {
	if user_id <= 0 || old_username == '' || username == '' || old_username == username {
		return error('invalid username change')
	}
	target_user_id := user_id
	old_name := old_username
	mut tx := db_begin_transaction(mut app.db)!
	mut committed := false
	defer {
		if !committed {
			tx.rollback() or {}
		}
	}
	repos := sql tx {
		select from Repo where user_id == target_user_id && user_name == old_name
	}!
	for repo in repos {
		new_git_dir := if repo.git_dir == '' {
			''
		} else {
			rebase_user_repo_git_dir(app.config.repo_storage_path, old_username, username, repo.git_dir)!
		}
		repo_id := repo.id
		sql tx {
			update Repo set user_name = username, git_dir = new_git_dir where id == repo_id
		}!
	}
	now := int(time.now().unix())
	sql tx {
		update User set username = username, namechanges_count = namechanges_count + 1, last_namechange_time = now
		where id == target_user_id
	}!
	tx.commit()!
	committed = true
}

fn rebase_user_repo_git_dir(storage_root string, old_username string, new_username string, git_dir string) !string {
	old_owner_abs := os.abs_path(os.join_path(storage_root, old_username)).trim_right(os.path_separator)
	repo_abs := os.abs_path(git_dir).trim_right(os.path_separator)
	old_prefix := old_owner_abs + os.path_separator
	if repo_abs == old_owner_abs || !repo_abs.starts_with(old_prefix) {
		return error('repository path is outside the user storage directory')
	}
	relative_repo_path := repo_abs[old_prefix.len..]
	new_storage_root := if os.is_abs_path(git_dir) {
		os.abs_path(storage_root)
	} else {
		storage_root
	}
	return os.join_path(new_storage_root, new_username, relative_repo_path)
}

fn (mut app App) change_full_name(user_id int, full_name string) ! {
	sql app.db {
		update User set full_name = full_name where id == user_id
	}!
}

fn (mut app App) check_username(username string) (bool, User) {
	if username.len == 0 {
		return false, User{}
	}
	mut user := app.get_user_by_username(username) or { return false, User{} }
	return user.is_registered, user
}

pub fn (mut app App) auth_user(mut ctx Context, user User, ip string) ! {
	token := app.add_token(user.id, ip)!
	app.reset_user_login_throttle(user.id)!
	expire_date := time.now().add_seconds(session_ttl)
	// HttpOnly keeps the session token out of reach of JavaScript (so an XSS
	// payload can't steal it); SameSite=Lax stops the cookie from riding along
	// on cross-site requests, mitigating CSRF. Set `secure: true` as well when
	// deploying behind HTTPS.
	ctx.set_cookie(
		name:      'token'
		value:     token
		expires:   expire_date
		path:      '/'
		http_only: true
		same_site: .same_site_lax_mode
		secure:    app.config.cookie_secure
	)
}

pub fn (mut app App) is_logged_in(mut ctx Context) bool {
	token_cookie := ctx.get_cookie('token') or { return false }
	token := app.get_token(token_cookie) or { return false }
	user := app.get_user_by_id(token.user_id) or { return false }
	if user.is_blocked || !user.is_registered {
		app.handle_logout(mut ctx)
		return false
	}
	return true
}

pub fn (mut app App) get_user_from_cookies(ctx &Context) ?User {
	token_cookie := ctx.get_cookie('token') or { return none }
	token := app.get_token(token_cookie) or { return none }
	mut user := app.get_user_by_id(token.user_id) or { return none }
	return user
}

// activity_level maps a per-day commit count to a heatmap intensity level 0..4,
// scaled by the user's busiest day across the window.
fn activity_level(count int, max int) int {
	if count <= 0 || max <= 0 {
		return 0
	}
	ratio := f64(count) / f64(max)
	if ratio > 0.75 {
		return 4
	}
	if ratio > 0.5 {
		return 3
	}
	if ratio > 0.25 {
		return 2
	}
	return 1
}
