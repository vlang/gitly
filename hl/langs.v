// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module hl

const (
	lang_path = 'langs'
)

const (
	langs = init_langs()
)

struct Lang {
	keywords        []string
	lang_extensions []string
	string_start    []string
pub:
	line_comments   string
	mline_comments  []string
	color           string
	name            string
}

fn is_source(ext string) bool {
	extension_to_lang(ext) or { return false }
	return true
}

pub fn extension_to_lang(ext string) ?Lang {
	ending := ext.split('.').last()
	for lang in langs {
		if ending in lang.lang_extensions {
			return lang
		}
	}
	return error('No language found')
}

fn init_langs() []Lang {
	mut langs := []Lang{cap: 10}
	langs << init_c()
	langs << init_v()
	langs << init_js()
	langs << init_go()
	langs << init_cpp()
	langs << init_py()
	langs << init_ts()
	return langs
}
