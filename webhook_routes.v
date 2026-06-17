// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import veb
import validation

@['/:username/:repo_name/settings/webhooks']
pub fn (mut app App) repo_webhooks(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect_to_repository(username, repo_name)
	}
	webhooks := app.list_repo_webhooks(repo.id)
	return $veb.html('templates/repo/webhooks.html')
}

@['/:username/:repo_name/settings/webhooks/new']
pub fn (mut app App) new_webhook(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect_to_repository(username, repo_name)
	}
	return $veb.html('templates/new/webhook.html')
}

@['/:username/:repo_name/settings/webhooks'; post]
pub fn (mut app App) handle_create_webhook(mut ctx Context, username string, repo_name string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect_to_repository(username, repo_name)
	}
	url := ctx.form['url'].trim_space()
	secret := ctx.form['secret']
	// Reject empty URLs, non-http(s) schemes, and destinations that resolve to
	// internal/loopback/link-local addresses (SSRF protection).
	if validation.is_string_empty(url) || !is_safe_webhook_url(url) {
		return ctx.redirect('/${username}/${repo_name}/settings/webhooks/new')
	}
	mut events := []string{}
	for ev in ['push', 'issue', 'pr', 'comment', 'release'] {
		if ctx.form['event_${ev}'] == 'on' {
			events << ev
		}
	}
	events_str := if events.len == 0 { 'push,issue,pr,comment,release' } else { events.join(',') }
	app.add_webhook(repo.id, url, secret, events_str) or {
		ctx.error('Could not create webhook')
		return ctx.redirect('/${username}/${repo_name}/settings/webhooks/new')
	}
	return ctx.redirect('/${username}/${repo_name}/settings/webhooks')
}

@['/:username/:repo_name/settings/webhooks/:id/delete'; post]
pub fn (mut app App) handle_delete_webhook(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect_to_repository(username, repo_name)
	}
	wh := app.find_webhook_by_id(id.int()) or { return ctx.not_found() }
	if wh.repo_id != repo.id {
		return ctx.not_found()
	}
	app.delete_webhook(wh.id) or {}
	return ctx.redirect('/${username}/${repo_name}/settings/webhooks')
}

@['/:username/:repo_name/settings/webhooks/:id']
pub fn (mut app App) view_webhook(mut ctx Context, username string, repo_name string, id string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_admin_repo(ctx, repo) {
		return ctx.redirect_to_repository(username, repo_name)
	}
	webhook := app.find_webhook_by_id(id.int()) or { return ctx.not_found() }
	if webhook.repo_id != repo.id {
		return ctx.not_found()
	}
	deliveries := app.recent_webhook_deliveries(webhook.id, 30)
	return $veb.html('templates/repo/webhook.html')
}
