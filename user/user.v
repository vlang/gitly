module main

import crypto.sha256
import crypto.bcrypt
import time
import os

// bcrypt_cost is the work factor for password hashing. 12 is a good balance of
// security and speed on current hardware.
const bcrypt_cost = 12

struct User {
	id              int @[primary; sql: serial]
	full_name       string
	username        string @[unique]
	github_username string
	password        string
	salt            string
	created_at      time.Time
	is_github       bool
	is_registered   bool
	is_blocked      bool
	is_admin        bool
	oauth_state     string @[skip]
mut:
	// for github oauth XSRF protection
	namechanges_count    int
	last_namechange_time int
	posts_count          int
	last_post_time       int
	avatar               string
	emails               []Email @[skip]
	login_attempts       int
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

// hash_password_with_salt returns a bcrypt hash of the password. bcrypt
// generates and embeds its own random salt with a tunable cost factor, so the
// `salt` argument is ignored for new hashes (kept only so existing callers and
// the User.salt column are unaffected).
fn hash_password_with_salt(password string, salt string) string {
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
	return !hashed.starts_with('$2')
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
	mut user := app.get_user_by_username(username) or { User{} }

	if user.id != 0 && user.is_registered {
		app.info('User ${username} already exists')
		return error('username `${username}` is already taken')
	}

	// A non-registered row with this username exists (e.g. a GitHub shadow user).
	// Block normal registration; the GitHub flow handles upgrading shadow users itself.
	if user.id != 0 && !github {
		app.info('Username ${username} is reserved by an unregistered/shadow user')
		return error('username `${username}` is already taken')
	}

	user = app.get_user_by_email(emails[0]) or { User{} }

	if user.id != 0 && user.is_registered {
		app.info('Email ${emails[0]} is already in use')
		return error('email `${emails[0]}` is already in use')
	}

	if user.id == 0 {
		// Final guard: make sure no Email row points at this address even if
		// the parent user lookup didn't surface (orphaned/duplicate rows).
		if app.email_exists(emails[0]) {
			return error('email `${emails[0]}` is already in use')
		}

		user = User{
			username:        username
			password:        password
			salt:            salt
			created_at:      time.now()
			is_registered:   true
			is_github:       github
			github_username: username
			avatar:          default_avatar_name
			is_admin:        is_admin
		}

		app.add_user(user) or {
			if is_unique_constraint_error(err) {
				return error('username `${username}` or email `${emails[0]}` is already in use')
			}
			return err
		}

		mut u := app.get_user_by_username(user.username) or {
			app.info('User was not inserted')
			return error('user `${username}` was not inserted (lookup after insert failed: ${err})')
		}

		if u.password != user.password {
			app.info('User was not inserted (password mismatch after insert)')
			return error('user `${username}` was not inserted (password mismatch after insert)')
		}
		if u.username != user.username {
			app.info('User was not inserted (username mismatch after insert)')
			return error('user `${username}` was not inserted (username mismatch after insert: got `${u.username}`)')
		}

		app.add_activity(u.id, 'joined')!

		for email in emails {
			app.add_email(u.id, email) or {
				if is_unique_constraint_error(err) {
					return error('email `${email}` is already in use')
				}
				return err
			}
		}

		u.emails = app.find_user_emails(u.id)
	} else {
		// Update existing user
		if !github {
			app.create_user_dir(username)

			return true
		}

		if user.is_registered {
			sql app.db {
				update User set is_github = true where id == user.id
			}!
			return true
		}
	}
	app.create_user_dir(username)

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
	q :=
		'select id, full_name, username, avatar from ${sql_table('User')} where is_blocked is false and ' +
		'(username like ${sql_like_pattern(query)} or full_name like ${sql_like_pattern(query)})'
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
	user.posts_count++

	u := *user
	id := u.id
	now := int(time.now().unix())
	lastplus := int(time.unix(u.last_post_time).add_days(1).unix())

	if now >= lastplus {
		user.last_post_time = now
		sql app.db {
			update User set posts_count = 0, last_post_time = now where id == id
		}!
	}

	sql app.db {
		update User set posts_count = posts_count + 1 where id == id
	}!
}

pub fn (mut app App) increment_user_login_attempts(user_id int) ! {
	sql app.db {
		update User set login_attempts = login_attempts + 1 where id == user_id
	}!
}

pub fn (mut app App) update_user_login_attempts(user_id int, attempts int) ! {
	sql app.db {
		update User set login_attempts = attempts where id == user_id
	}!
}

pub fn (mut app App) check_user_blocked(user_id int) bool {
	user := app.get_user_by_id(user_id) or { return false }
	return user.is_blocked
}

fn (mut app App) change_username(user_id int, username string) ! {
	sql app.db {
		update User set username = username where id == user_id
	}!

	sql app.db {
		update Repo set user_name = username where user_id == user_id
	}!
}

fn (mut app App) change_full_name(user_id int, full_name string) ! {
	sql app.db {
		update User set full_name = full_name where id == user_id
	}!
}

fn (mut app App) incement_namechanges(user_id int) ! {
	now := int(time.now().unix())
	sql app.db {
		update User set namechanges_count = namechanges_count + 1, last_namechange_time = now
		where id == user_id
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
	app.update_user_login_attempts(user.id, 0)!
	expire_date := time.now().add_days(200)
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
	)
}

pub fn (mut app App) is_logged_in(mut ctx Context) bool {
	token_cookie := ctx.get_cookie('token') or { return false }
	token := app.get_token(token_cookie) or { return false }
	is_user_blocked := app.check_user_blocked(token.user_id)
	if is_user_blocked {
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
