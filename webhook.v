// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import net.http
import crypto.hmac
import crypto.sha256
import encoding.hex
import x.json2 as json

pub struct WebhookIssuePayload {
	action string
	repo   string
	title  string
	author string
}

pub struct WebhookPrPayload {
	action string
	repo   string
	number int
	title  string
	author string
	head   string
	base   string
}

pub struct WebhookCommentPayload {
	action string
	repo   string
	target string // 'issue' or 'pr'
	number int
	author string
	text   string
}

pub struct WebhookReleasePayload {
	action string
	repo   string
	tag    string
	author string
}

pub struct WebhookPushPayload {
	repo   string
	ref    string
	author string
}

struct Webhook {
	id int @[primary; sql: serial]
mut:
	repo_id       int
	url           string
	secret        string
	events        string // comma-separated: push,issue,pr,comment,release
	is_active     bool
	created_at    int
	last_status   int
	last_delivery int
}

struct WebhookDelivery {
	id int @[primary; sql: serial]
mut:
	webhook_id    int
	event         string
	status_code   int
	response_body string
	created_at    int
}

fn (w &Webhook) has_event(name string) bool {
	if w.events == '' {
		return true
	}
	for ev in w.events.split(',') {
		if ev.trim_space() == name {
			return true
		}
	}
	return false
}

fn (w &Webhook) event_list() []string {
	mut out := []string{}
	for ev in w.events.split(',') {
		t := ev.trim_space()
		if t != '' {
			out << t
		}
	}
	return out
}

fn (mut app App) add_webhook(repo_id int, url string, secret string, events string) ! {
	wh := Webhook{
		repo_id:    repo_id
		url:        url
		secret:     secret
		events:     events
		is_active:  true
		created_at: int(time.now().unix())
	}
	sql app.db {
		insert wh into Webhook
	}!
}

fn (mut app App) list_repo_webhooks(repo_id int) []Webhook {
	return sql app.db {
		select from Webhook where repo_id == repo_id order by id desc
	} or { []Webhook{} }
}

fn (mut app App) find_webhook_by_id(id int) ?Webhook {
	rows := sql app.db {
		select from Webhook where id == id limit 1
	} or { []Webhook{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) delete_webhook(id int) ! {
	sql app.db {
		delete from Webhook where id == id
	}!
	sql app.db {
		delete from WebhookDelivery where webhook_id == id
	}!
}

fn (mut app App) delete_repo_webhooks(repo_id int) ! {
	whs := app.list_repo_webhooks(repo_id)
	for wh in whs {
		app.delete_webhook(wh.id) or {}
	}
}

fn (mut app App) toggle_webhook(id int, active bool) ! {
	sql app.db {
		update Webhook set is_active = active where id == id
	}!
}

fn (mut app App) record_webhook_delivery(webhook_id int, event string, status int, body string) {
	d := WebhookDelivery{
		webhook_id:    webhook_id
		event:         event
		status_code:   status
		response_body: body
		created_at:    int(time.now().unix())
	}
	sql app.db {
		insert d into WebhookDelivery
	} or { return }
	sql app.db {
		update Webhook set last_status = status, last_delivery = d.created_at where id == webhook_id
	} or { return }
}

fn (mut app App) recent_webhook_deliveries(webhook_id int, limit int) []WebhookDelivery {
	return sql app.db {
		select from WebhookDelivery where webhook_id == webhook_id order by id desc limit limit
	} or { []WebhookDelivery{} }
}

// dispatch_webhook fires a webhook delivery in a background spawn.
// payload is any serializable value; it's JSON-encoded with `json.encode`.
fn (mut app App) dispatch_webhook[T](repo_id int, event string, payload T) {
	body := json.encode(payload)
	app.fan_out_webhook(repo_id, event, body)
}

fn (mut app App) fan_out_webhook(repo_id int, event string, body string) {
	hooks := app.list_repo_webhooks(repo_id)
	for wh in hooks {
		if !wh.is_active {
			continue
		}
		if !wh.has_event(event) {
			continue
		}
		spawn app.deliver_webhook(wh, event, body)
	}
}

fn (mut app App) deliver_webhook(wh Webhook, event string, body string) {
	mut signature := ''
	if wh.secret != '' {
		sig_bytes := hmac.new(wh.secret.bytes(), body.bytes(), sha256.sum, sha256.block_size)
		signature = 'sha256=' + hex.encode(sig_bytes)
	}
	mut req := http.new_request(.post, wh.url, body)
	req.header.add(.content_type, 'application/json')
	req.header.add_custom('X-Gitly-Event', event) or {}
	if signature != '' {
		req.header.add_custom('X-Gitly-Signature', signature) or {}
	}
	req.read_timeout = 10 * time.second
	req.write_timeout = 10 * time.second
	resp := req.do() or {
		app.record_webhook_delivery(wh.id, event, 0, err.str())
		return
	}
	preview := if resp.body.len > 500 { resp.body[..500] } else { resp.body }
	app.record_webhook_delivery(wh.id, event, resp.status_code, preview)
}
