// Copyright (c) 2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import crypto.hmac
import encoding.base64
import veb

@['/:username/:repo_name/pull/:id/ai-fix']
pub fn (mut app App) pull_request_ai_fix(mut ctx Context, username string, repo_name string, id string) veb.Result {
	return app.render_ai_fix(mut ctx, username, repo_name, id, false)
}

@['/:username/:repo_name/pull/:id/ai-fix'; post]
pub fn (mut app App) generate_pull_request_ai_fix(mut ctx Context, username string, repo_name string, id string) veb.Result {
	return app.render_ai_fix(mut ctx, username, repo_name, id, true)
}

fn (mut app App) render_ai_fix(mut ctx Context, username string, repo_name string, id string, generate bool) veb.Result {
	ctx.set_header(.cache_control, 'no-store')
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	state := app.ai_fix_context(ctx.user.id, repo, pr) or {
		ctx.res.set_status(.conflict)
		return ctx.text(err.msg())
	}
	source_repo := state.source_repo
	ci_status := state.ci_status
	head_oid := state.head_oid
	csrf_token := ai_fix_csrf_token(app.config.ci_secret, ctx.get_cookie('token') or { '' },
		repo.id, pr.id)
	if csrf_token == '' {
		ctx.res.set_status(.forbidden)
		return ctx.text('A valid session is required')
	}
	mut provider := 'claude'
	mut model := ''
	mut suggestion := AiFixSuggestion{}
	mut has_suggestion := false
	mut error_msg := ''
	if generate {
		if !hmac.equal(csrf_token.bytes(), ctx.form['csrf_token'].bytes()) {
			ctx.res.set_status(.forbidden)
			return ctx.text('Invalid form token. Reload this page and try again')
		}
		if ctx.form['head_oid'] != head_oid || ctx.form['ci_run_id'] != ci_status.ci_run_id.str() {
			ctx.res.set_status(.conflict)
			return ctx.text('The source commit or CI run changed. Reload the pull request')
		}
		provider = if ctx.form['provider'] in ['claude', 'codex'] {
			ctx.form['provider']
		} else {
			''
		}
		model = ctx.form['model'].trim_space()
		suggestion = app.generate_ai_fix(state, provider, ctx.form['api_key'], model) or {
			error_msg = err.msg()
			AiFixSuggestion{}
		}
		has_suggestion = error_msg == ''
	}
	patch_base64 := base64.encode_str(suggestion.patch)
	ctx.set_page_title(['Fix with Gitly AI', '${repo.user_name}/${repo.name}', '#${pr.id}'])
	return $veb.html('templates/pull_ai_fix.html')
}

fn (mut app App) generate_ai_fix(state AiFixContext, provider string, api_key string, model string) !AiFixSuggestion {
	// Validate inputs before fetching logs or spending a provider request.
	ai_fix_fetch_config(provider, api_key, model, 'Validate request')!
	prompt := app.ai_fix_prompt(state)!
	suggestion := ai_fix_request(provider, api_key, model, prompt)!
	if suggestion.patch == '' {
		return suggestion
	}
	prepared := prepare_ai_fix_patch(state.source_repo, state.head_oid, suggestion.patch)!
	return AiFixSuggestion{ summary: suggestion.summary, patch: prepared.patch }
}

@['/:username/:repo_name/pull/:id/ai-fix/apply'; post]
pub fn (mut app App) apply_pull_request_ai_fix(mut ctx Context, username string, repo_name string, id string) veb.Result {
	ctx.set_header(.cache_control, 'no-store')
	if !ctx.logged_in {
		return ctx.redirect_to_login()
	}
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }
	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	pr := app.find_pull_request_by_id(id.int()) or { return ctx.not_found() }
	if pr.repo_id != repo.id {
		return ctx.not_found()
	}
	csrf_token := ai_fix_csrf_token(app.config.ci_secret, ctx.get_cookie('token') or { '' },
		repo.id, pr.id)
	if csrf_token == '' || !hmac.equal(csrf_token.bytes(), ctx.form['csrf_token'].bytes()) {
		ctx.res.set_status(.forbidden)
		return ctx.text('Invalid form token. Reload the pull request and try again')
	}
	state := app.ai_fix_context(ctx.user.id, repo, pr) or {
		ctx.res.set_status(.conflict)
		return ctx.text(err.msg())
	}
	if ctx.form['head_oid'] != state.head_oid
		|| ctx.form['ci_run_id'] != state.ci_status.ci_run_id.str() {
		ctx.res.set_status(.conflict)
		return ctx.text('The source commit or CI run changed. Generate a new fix')
	}
	patch := ai_fix_decode_patch(ctx.form['patch_base64']) or {
		ctx.res.set_status(.bad_request)
		return ctx.text(err.msg())
	}
	commit_ai_fix_patch(state.source_repo, pr.head_branch, state.head_oid, patch,
		ctx.user.username) or {
		ctx.res.set_status(.conflict)
		return ctx.text(err.msg())
	}
	app.update_repo_after_push(state.source_repo.id, pr.head_branch) or {
		app.warn('Gitly AI committed a fix but repository refresh failed: ${err}')
		ctx.error('Fix committed, but repository metadata could not be refreshed')
	}
	spawn run_ci_trigger_if_configured(state.source_repo.id, pr.head_branch, app.config)
	return ctx.redirect('/${repo.user_name}/${repo.name}/pull/${pr.id}')
}

// Hidden base64 preserves patch bytes across browser form newline conversion.
fn ai_fix_decode_patch(encoded string) !string {
	if encoded.len == 0 || encoded.len > (ai_fix_max_patch_bytes + 2) / 3 * 4 {
		return error('The submitted patch is empty or too large')
	}
	patch := base64.decode_str(encoded)
	if base64.encode_str(patch) != encoded || patch.len > ai_fix_max_patch_bytes {
		return error('The submitted patch encoding is invalid')
	}
	return patch
}
