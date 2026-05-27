// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import validation

@['/organizations/new']
pub fn (mut app App) new_org(mut ctx Context) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	return $veb.html('templates/new/org.html')
}

@['/organizations/new'; post]
pub fn (mut app App) handle_new_org(mut ctx Context) veb.Result {
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	org_name := ctx.form['org_name']
	contact_email := ctx.form['contact_email']
	org_kind := ctx.form['org_kind']
	accept_terms := ctx.form['accept_terms'] == '1'

	if validation.is_string_empty(org_name) {
		ctx.error('Organization name is required')
		return app.new_org(mut ctx)
	}
	if org_name.len > max_username_len {
		ctx.error('The organization name is too long (should be fewer than ${max_username_len} characters)')
		return app.new_org(mut ctx)
	}
	if org_name.contains(' ') {
		ctx.error('Organization name cannot contain spaces')
		return app.new_org(mut ctx)
	}
	if validation.is_string_empty(contact_email) {
		ctx.error('Contact email is required')
		return app.new_org(mut ctx)
	}
	if org_kind != 'personal' && org_kind != 'business' {
		ctx.error('Please select who this organization belongs to')
		return app.new_org(mut ctx)
	}
	if !accept_terms {
		ctx.error('You must accept the Terms of Service')
		return app.new_org(mut ctx)
	}
	if _ := app.get_user_by_username(org_name) {
		ctx.error('The name "${org_name}" is already taken')
		return app.new_org(mut ctx)
	}
	if _ := app.get_org_by_name(org_name) {
		ctx.error('The name "${org_name}" is already taken')
		return app.new_org(mut ctx)
	}

	org_id := app.add_org(org_name, contact_email, org_kind, ctx.user.id) or {
		ctx.error('Could not create organization: ${err}')
		return app.new_org(mut ctx)
	}
	app.add_org_member(org_id, ctx.user.id, 'admin') or {
		ctx.error('Could not add you as the organization owner: ${err}')
		return app.new_org(mut ctx)
	}
	return ctx.redirect('/new?owner=${org_name}')
}
