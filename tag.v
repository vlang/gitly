// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import  time

struct Tag {
mut:
	name   string		// tag name
	author string		// author of commit
	hash   string		// hash of latest commit on tag
	date   time.Time	// time of latest commit on tag
}

fn get_tags(r Repo) []Tag {
	mut tags := []Tag{}
	mut tag := Tag{}
	data := r.git('ls-remote -tq')
	for remote_tag in data.split_into_lines() {
		tag.name = remote_tag.after('refs/tags/')
		tag.hash = remote_tag.substr(0, 7)
		tag_hash_data := r.git('log -1 --pretty="%aE$log_field_separator%cD" $tag.hash')
		args := tag_hash_data.split(log_field_separator)
		if args.len < 2 {
			continue
		}
		tag.author = args[0]
		tag.date = time.parse_rfc2822(args[1]) or {
			eprintln('Error: $err')
			return tags
		}
		tags << tag
	}
	tags.sort_with_compare(compare_time)
	return tags
}
