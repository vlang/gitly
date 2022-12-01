module main

import os

const (
	default_avatar_name  = 'default_avatar.png'
	assets_path          = 'assets'
	avatar_max_file_size = 1 * 1024 * 1024 // 1 megabyte
	supported_mime_types = [
		'image/jpeg',
		'image/png',
		'image/webp',
	]
)

fn validate_avatar_content_type(content_type string) bool {
	return supported_mime_types.contains(content_type)
}

fn extract_file_extension_from_mime_type(mime_type string) ?string {
	is_valid_mime_type := validate_avatar_content_type(mime_type)

	if !is_valid_mime_type {
		return error('MIME type is not supported')
	}

	mime_parts := mime_type.split('/')

	return mime_parts[1]
}

fn validate_avatar_file_size(content string) bool {
	return content.len <= avatar_max_file_size
}

fn (app App) build_avatar_file_path(avatar_filename string) string {
	relative_path := os.join_path(app.config.avatars_path, avatar_filename)

	return os.abs_path(relative_path)
}

fn (app App) build_avatar_file_url(avatar_filename string) string {
	clean_path := app.config.avatars_path.trim_string_left('./')

	return os.join_path('/', clean_path, avatar_filename)
}

fn (app App) write_user_avatar(avatar_filename string, file_content string) bool {
	path := os.join_path(app.config.avatars_path, avatar_filename)

	os.write_file(path, file_content) or { return false }

	return true
}

fn (app App) prepare_user_avatar_url(avatar_filename_or_url string) string {
	is_url := avatar_filename_or_url.starts_with('http')
	is_default_avatar := avatar_filename_or_url == default_avatar_name

	if is_url {
		return avatar_filename_or_url
	}

	if is_default_avatar {
		return os.join_path('/', assets_path, avatar_filename_or_url)
	}

	return app.build_avatar_file_url(avatar_filename_or_url)
}
