// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import net
import net.http
import net.urllib
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

// is_blocked_ipv4 reports whether the dotted-quad IPv4 string falls in a range
// a webhook must never reach: unspecified (0/8), loopback (127/8), private
// (10/8, 172.16/12, 192.168/16), CGNAT (100.64/10), link-local (169.254/16,
// which includes the cloud metadata address 169.254.169.254), and
// multicast/reserved (>=224). Unparseable input is treated as blocked.
fn is_blocked_ipv4(ip string) bool {
	parts := ip.split('.')
	if parts.len != 4 {
		return true
	}
	mut o := [4]int{}
	for i in 0 .. 4 {
		if parts[i] == '' {
			return true
		}
		n := parts[i].int()
		if n < 0 || n > 255 {
			return true
		}
		o[i] = n
	}
	return o[0] == 0 || o[0] == 10 || o[0] == 127 || (o[0] == 169 && o[1] == 254)
		|| (o[0] == 172 && o[1] >= 16 && o[1] <= 31) || (o[0] == 192 && o[1] == 168)
		|| (o[0] == 100 && o[1] >= 64 && o[1] <= 127) || o[0] >= 224
}

// is_blocked_ipv6 reports whether the IPv6 text (no brackets) is loopback (::1),
// unspecified (::), unique-local (fc00::/7), link-local (fe80::/10), or an
// IPv4-mapped address (e.g. ::ffff:127.0.0.1) pointing at a blocked IPv4.
fn is_blocked_ipv6(ip_in string) bool {
	ip := ip_in.to_lower()
	if ip == '::1' || ip == '::' {
		return true
	}
	// IPv4-mapped/-compatible forms end in a dotted quad.
	if ip.contains('.') {
		tail := ip.all_after_last(':')
		if tail.contains('.') {
			return is_blocked_ipv4(tail)
		}
	}
	if ip.starts_with('fc') || ip.starts_with('fd') {
		return true
	}
	if ip.starts_with('fe8') || ip.starts_with('fe9') || ip.starts_with('fea')
		|| ip.starts_with('feb') {
		return true
	}
	return false
}

// is_safe_webhook_url validates a webhook destination before any server-side
// request is made: the scheme must be http(s), the host must resolve, and none
// of the resolved addresses may be loopback/private/link-local. Resolving here
// blocks hostnames that point at internal IPs; it cannot fully defeat DNS
// rebinding between this check and delivery, but it closes the common SSRF
// vectors (literal internal IPs, localhost, cloud metadata endpoints).
fn is_safe_webhook_url(raw string) bool {
	u := urllib.parse(raw) or { return false }
	scheme := u.scheme.to_lower()
	if scheme != 'http' && scheme != 'https' {
		return false
	}
	host := u.hostname()
	if host == '' {
		return false
	}
	lhost := host.to_lower()
	if lhost == 'localhost' || lhost.ends_with('.localhost') {
		return false
	}
	port := if u.port() != '' {
		u.port()
	} else if scheme == 'https' {
		'443'
	} else {
		'80'
	}
	addrs := net.resolve_addrs('${host}:${port}', .unspec, .tcp) or { return false }
	if addrs.len == 0 {
		return false
	}
	for a in addrs {
		s := a.str()
		match a.family() {
			.ip {
				if is_blocked_ipv4(s.all_before_last(':')) {
					return false
				}
			}
			.ip6 {
				if is_blocked_ipv6(s.find_between('[', ']')) {
					return false
				}
			}
			else {
				return false
			}
		}
	}
	return true
}

fn (mut app App) deliver_webhook(wh Webhook, event string, body string) {
	// Re-validate at delivery time: this is the authoritative SSRF gate. It
	// also protects webhooks created before this check existed and catches
	// hosts whose DNS now points at an internal address.
	if !is_safe_webhook_url(wh.url) {
		app.record_webhook_delivery(wh.id, event, 0,
			'blocked: destination resolves to a disallowed (internal/loopback) address')
		return
	}
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
