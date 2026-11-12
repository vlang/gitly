module main

import net.http
import time
import crypto.hmac
import crypto.sha256
import encoding.hex

fn ci_service_signature(secret string, timestamp string, method string, path string, body string) string {
	canonical_path := path.all_before('?')
	payload := '${timestamp}\n${method.to_upper()}\n${canonical_path}\n${body}'
	mac := hmac.new(secret.bytes(), payload.bytes(), sha256.sum, sha256.block_size)
	return 'sha256=' + hex.encode(mac)
}

fn (app &App) ci_service_request(method http.Method, path string, body string) !http.Response {
	return app.ci_service_request_limited(method, path, body, 0)
}

fn (app &App) ci_service_request_limited(method http.Method, path string, body string, max_bytes int) !http.Response {
	if app.config.ci_service_url.trim_space() == '' {
		return error('CI service is not configured')
	}
	if app.config.ci_secret == '' {
		return error('CI service authentication is not configured')
	}
	if !path.starts_with('/api/v1/') || path.contains_any('\x00\r\n') {
		return error('Invalid CI service path')
	}
	timestamp := time.now().unix().str()
	mut header := http.Header{}
	header.add_custom('X-Gitly-CI-Timestamp', timestamp)!
	header.add_custom('X-Gitly-CI-Signature', ci_service_signature(app.config.ci_secret, timestamp,
		method.str(), path, body))!
	if body != '' {
		header.add(.content_type, 'application/json')
	}
	return http.fetch(http.FetchConfig{
		url:                  app.config.ci_service_url.trim_right('/') + path
		method:               method
		data:                 body
		header:               header
		allow_redirect:       false
		read_timeout:         15 * time.second
		write_timeout:        15 * time.second
		max_retries:          1
		stop_copying_limit:   if max_bytes > 0 { i64(max_bytes) + 1 } else { i64(-1) }
		stop_receiving_limit: if max_bytes > 0 { i64(max_bytes) + 64 * 1024 } else { i64(-1) }
	})
}
