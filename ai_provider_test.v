module main

import net.http
import time
import x.json2 as json

fn ai_provider_test_patch() string {
	return 'diff --git a/main.v b/main.v\n--- a/main.v\n+++ b/main.v\n@@ -1 +1 @@\n-old\n+new\n'
}

fn ai_provider_config_is_error(provider string, key string, model string, prompt string) bool {
	ai_fix_fetch_config(provider, key, model, prompt) or { return true }
	return false
}

fn ai_provider_suggestion_is_error(text string) bool {
	ai_fix_parse_suggestion(text) or { return true }
	return false
}

fn ai_provider_response_is_error(provider string, status int, text string) bool {
	ai_fix_parse_response(provider, status, text) or { return true }
	return false
}

fn test_ai_provider_requests_use_fixed_destinations_and_single_use_credentials() {
	for provider in ['claude', 'codex'] {
		request := ai_fix_fetch_config(provider, 'test-api-key', '', 'failed CI context')!
		assert request.method == http.Method.post
		assert !request.allow_redirect
		assert request.validate
		assert request.max_retries == 1
		assert request.read_timeout == 90 * time.second
		assert request.write_timeout == 15 * time.second
		assert request.stop_copying_limit == ai_fix_max_response_bytes + 1
		assert request.stop_receiving_limit == ai_fix_max_response_bytes + 64 * 1024
		assert request.header.get(.content_type) or { '' } == 'application/json'
		assert !request.data.contains('test-api-key')
		if provider == 'claude' {
			assert request.url == 'https://api.anthropic.com/v1/messages'
			assert request.header.get_custom('x-api-key') or { '' } == 'test-api-key'
			assert request.header.get_custom('anthropic-version') or { '' } == '2026-10-21'
			body := json.decode[AiFixClaudeRequest](request.data)!
			assert body.model == ai_fix_default_model(provider)!
			assert body.max_tokens == 16384
			assert body.messages.len == 1
			assert body.messages[0].role == 'user'
			assert body.messages[0].content == 'failed CI context'
			assert body.system.contains('untrusted data')
		} else {
			assert request.url == 'https://api.openai.com/v1/responses'
			assert request.header.get(.authorization) or { '' } == 'Bearer test-api-key'
			body := json.decode[AiFixCodexRequest](request.data)!
			assert body.model == ai_fix_default_model(provider)!
			assert !body.store
			assert request.data.contains('"store":false')
			assert body.max_output_tokens == 16384
			assert body.input == 'failed CI context'
			assert body.instructions.contains('untrusted data')
		}
	}
}

fn test_ai_provider_rejects_unsafe_or_oversized_configuration_before_network_io() {
	assert ai_fix_model('claude', '')! == 'claude-sonnet-5-5'
	assert ai_fix_model('codex', '  custom-model:2026_11.1  ')! == 'custom-model:2026_11.1'
	assert ai_provider_config_is_error('https://attacker.test', 'test-key', '', 'context')
	assert ai_provider_config_is_error('codex', '', '', 'context')
	assert ai_provider_config_is_error('codex', 'test\r\nHeader: value', '', 'context')
	assert ai_provider_config_is_error('claude', 'test key', '', 'context')
	assert ai_provider_config_is_error('claude', 'a'.repeat(1025), '', 'context')
	assert ai_provider_config_is_error('codex', 'test-key', 'https://attacker.test', 'context')
	assert ai_provider_config_is_error('codex', 'test-key', 'model\nheader', 'context')
	assert ai_provider_config_is_error('codex', 'test-key', 'a'.repeat(121), 'context')
	assert ai_provider_config_is_error('codex', 'test-key', '', '')
	assert ai_provider_config_is_error('codex', 'test-key', '', 'a'.repeat(ai_fix_max_prompt_bytes + 1))
}

fn test_ai_provider_extracts_claude_text_and_codex_output_messages() {
	suggestion := AiFixSuggestion{
		summary: 'Fix the failing assertion.'
		patch:   ai_provider_test_patch()
	}
	text := json.encode(suggestion)
	claude := json.encode(AiFixClaudeResponse{
		type:        'message'
		role:        'assistant'
		stop_reason: 'end_turn'
		content:     [AiFixContentBlock{
			type: 'thinking'
			text: 'not part of the JSON output'
		}, AiFixContentBlock{
			type: 'text'
			text: text
		}]
	})
	assert ai_fix_parse_response('claude', 200, claude)! == suggestion
	codex := json.encode(AiFixCodexResponse{
		status: 'completed'
		output: [AiFixOutputItem{
			type: 'reasoning'
		}, AiFixOutputItem{
			type:    'message'
			role:    'assistant'
			status:  'completed'
			phase:   'commentary'
			content: [AiFixContentBlock{
				type: 'output_text'
				text: 'I will prepare a fix.'
			}]
		}, AiFixOutputItem{
			type:    'message'
			role:    'assistant'
			status:  'completed'
			phase:   'final'
			content: [AiFixContentBlock{
				type: 'output_text'
				text: text
			}]
		}]
	})
	assert ai_fix_parse_response('codex', 200, codex)! == suggestion
}

fn test_ai_provider_rejects_incomplete_refused_invalid_and_oversized_responses() {
	assert ai_provider_response_is_error('claude', 200,
		'{"type":"message","role":"assistant","stop_reason":"max_tokens","content":[]}')
	assert ai_provider_response_is_error('claude', 200,
		'{"type":"message","role":"assistant","stop_reason":"refusal","content":[]}')
	assert ai_provider_response_is_error('codex', 200,
		'{"status":"incomplete","output":[]}')
	assert ai_provider_response_is_error('codex', 200,
		'{"status":"completed","output":[{"type":"message","role":"assistant","status":"in_progress","content":[]}]}')
	assert ai_provider_response_is_error('codex', 200,
		'{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"refusal"}]}]}')
	assert ai_provider_response_is_error('codex', 200,
		'{"status":"completed","output":[]}')
	assert ai_provider_response_is_error('claude', 200, 'invalid json')
	assert ai_provider_response_is_error('codex', 200, '')
	assert ai_provider_response_is_error('claude', 200, 'x'.repeat(ai_fix_max_response_bytes + 1))
	for status in [302, 400, 401, 403, 429, 500] {
		ai_fix_parse_response('codex', status, 'sensitive-upstream-error-with-api-key') or {
			assert !err.msg().contains('sensitive-upstream-error-with-api-key')
			continue
		}
		assert false, 'non-successful provider response was accepted'
	}
}

fn test_ai_provider_requires_exact_typed_json_and_bounded_summary_and_patch() {
	valid := json.encode(AiFixSuggestion{
		summary: '  Fix syntax.  '
		patch:   ai_provider_test_patch()
	})
	assert ai_fix_parse_suggestion(valid)!.summary == 'Fix syntax.'
	assert ai_fix_parse_suggestion('{"summary":"More source context is needed.","patch":""}')!.patch == ''
	for invalid in [
		'not json',
		'{}',
		'{"summary":"missing patch"}',
		'{"summary":"extra field","patch":"","command":"rm -rf ."}',
		'{"summary":42,"patch":""}',
		'{"summary":"null patch","patch":null}',
		'{"summary":"array patch","patch":[]}',
		'{"summary":"","patch":""}',
		'{"summary":"explanation","patch":"run git reset"}',
		'{"summary":"ok","patch":""} trailing',
		'```json\n{"summary":"fenced","patch":""}\n```',
	] {
		assert ai_provider_suggestion_is_error(invalid), invalid
	}
	assert ai_provider_suggestion_is_error(json.encode(AiFixSuggestion{
		summary: 'a'.repeat(4097)
	}))
	assert ai_provider_suggestion_is_error(json.encode(AiFixSuggestion{
		summary: 'contains\x00null'
	}))
	assert ai_provider_suggestion_is_error(json.encode(AiFixSuggestion{
		summary: 'oversized patch'
		patch:   'diff --git ' + 'a'.repeat(ai_fix_max_patch_bytes)
	}))
}
