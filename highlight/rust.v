module highlight

// keywords suffixed with `reserved` are reserved by the compiler for future use

fn init_rust() Lang {
	return Lang{
		name:            'Rust'
		lang_extensions: ['rs']
		line_comments:   '//'
		mline_comments:  ['/*', '*/']
		string_start:    ['"', '"']
		color:           '#DDA483'
		keywords:        [
			"'static",
			'abstract', // reserved
			'as',
			'async',
			'await',
			'become', // reserved
			'box', // reserved
			'break',
			'const',
			'continue',
			'crate',
			'do', // reserved
			'dyn',
			'else',
			'enum',
			'extern',
			'false',
			'final', // reserved
			'fn',
			'for',
			'if',
			'impl',
			'in',
			'let',
			'loop',
			'macro', // reserved
			'macro_rules',
			'match',
			'mod',
			'move',
			'mut',
			'override', // reserved
			'pub',
			'priv', // reserved
			'ref',
			'return',
			'self',
			'Self',
			'static',
			'struct',
			'super',
			'trait',
			'true',
			'try',
			'type',
			'typeof', // reserved
			'union',
			'unsafe',
			'unsized', // reserved
			'use',
			'virtual', // reserved
			'where',
			'while',
			'yield', // reserved
		]
	}
}
