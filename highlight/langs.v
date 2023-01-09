// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module highlight

const (
	lang_path = 'langs'
)

const (
	langs = init_langs()
)

pub struct Lang {
	keywords        []string
	lang_extensions []string
	string_start    []string
pub:
	line_comments  string
	mline_comments []string
	color          string
	name           string
}

fn is_source(ext string) bool {
	extension_to_lang(ext) or { return false }
	return true
}

pub fn extension_to_lang(ext string) ?Lang {
	ending := ext.split('.').last()
	for lang in highlight.langs {
		if ending in lang.lang_extensions {
			return lang
		}
	}
	return error('No language found')
}

fn init_langs() []Lang {
	mut langs_ := []Lang{cap: 10}
	langs_ << init_c()
	langs_ << init_v()
	langs_ << init_js()
	langs_ << init_go()
	langs_ << init_cpp()
	langs_ << init_d()
	langs_ << init_py()
	langs_ << init_ts()
	return langs_
}
