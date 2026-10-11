module main

import veb
import os
import rand

@['/:username/:repo_name/tag/:tag/:format']
pub fn (mut app App) handle_download_tag_archive(mut ctx Context, username string, repo_name string, tag string, format string) veb.Result {
	return stream_tag_archive(mut app, mut ctx, username, repo_name, tag, format)
}

// The legacy route above cannot represent a tag containing `/`, because veb
// treats each slash as another route segment. Keep it for existing links and
// use this catch-all route for canonical release downloads.
@['/:username/:repo_name/archive/:tag...']
pub fn (mut app App) handle_download_tag_archive_path(mut ctx Context, username string, repo_name string, tag string) veb.Result {
	format := ctx.query['format'] or { '' }
	return stream_tag_archive(mut app, mut ctx, username, repo_name, tag, format)
}

fn stream_tag_archive(mut app App, mut ctx Context, username string, repo_name string, tag string, format string) veb.Result {
	repo := app.find_repo_by_name_and_username(repo_name, username) or { return ctx.not_found() }

	if !app.can_read_repo(ctx, repo) {
		return ctx.not_found()
	}
	if !is_safe_ref(tag) || format !in ['zip', 'tar', 'tar.gz'] {
		return ctx.not_found()
	}

	archive_abs_path := os.abs_path(app.config.archive_path)
	snapshot_format := format
	safe_tag_name := tag.replace('/', '-')
	snapshot_name := '${username}_${repo_name}_${safe_tag_name}.${snapshot_format}'
	tag_oid := git_rev_parse(repo.git_dir, 'refs/tags/${tag}') or { return ctx.not_found() }
	cache_name := '${username}_${repo_name}_${safe_tag_name}_${tag_oid}.${snapshot_format}'
	archive_path := os.join_path(archive_abs_path, cache_name)
	archive_format := match format {
		'zip' { ArchiveFormat.zip }
		'tar.gz' { ArchiveFormat.tar_gz }
		else { ArchiveFormat.tar }
	}
	if !os.exists(archive_path) {
		os.mkdir_all(archive_abs_path) or { return ctx.not_found() }
		tmp_path := '${archive_path}.tmp-${os.getpid()}-${rand.ulid()}'
		repo.archive_tag(tag, tmp_path, archive_format) or {
			os.rm(tmp_path) or {}
			return ctx.not_found()
		}
		os.mv(tmp_path, archive_path, overwrite: false) or {
			// Another request may have populated the immutable cache first.
			os.rm(tmp_path) or {}
			if !os.exists(archive_path) {
				return ctx.not_found()
			}
		}
	}

	ctx.set_header(.content_disposition, 'attachment; filename="${snapshot_name}"')
	ctx.set_header(.cache_control, if repo.is_public {
		'public, max-age=31536000, immutable'
	} else {
		'private, max-age=3600'
	})
	return ctx.file(archive_path)
}
