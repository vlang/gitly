// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time

struct Org {
	id            int    @[primary; sql: serial]
	name          string @[unique]
	contact_email string
	kind          string
	created_at    time.Time
	created_by    int
}

struct OrgMember {
	id      int @[primary; sql: serial]
	org_id  int @[unique: 'org_member']
	user_id int @[unique: 'org_member']
	role    string
}

pub fn (mut app App) add_org(name string, contact_email string, kind string, created_by int) !int {
	new_org := Org{
		name:          name
		contact_email: contact_email
		kind:          kind
		created_at:    time.now()
		created_by:    created_by
	}
	sql app.db {
		insert new_org into Org
	}!
	row := app.get_org_by_name(name) or { return error('failed to load newly created org') }
	return row.id
}

pub fn (app App) get_org_by_name(name string) ?Org {
	rows := sql app.db {
		select from Org where name == name limit 1
	} or { [] }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

pub fn (app App) get_org_by_id(id int) ?Org {
	rows := sql app.db {
		select from Org where id == id limit 1
	} or { [] }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

pub fn (mut app App) add_org_member(org_id int, user_id int, role string) ! {
	member := OrgMember{
		org_id:  org_id
		user_id: user_id
		role:    role
	}
	sql app.db {
		insert member into OrgMember
	}!
}

pub fn (app App) find_orgs_for_user(user_id int) []Org {
	members := sql app.db {
		select from OrgMember where user_id == user_id
	} or { [] }
	mut orgs := []Org{cap: members.len}
	for m in members {
		org := app.get_org_by_id(m.org_id) or { continue }
		orgs << org
	}
	return orgs
}

pub fn (app App) is_org_member(org_id int, user_id int) bool {
	count := sql app.db {
		select count from OrgMember where org_id == org_id && user_id == user_id
	} or { 0 }
	return count > 0
}
