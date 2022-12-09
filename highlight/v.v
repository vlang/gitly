module highlight

fn init_v() Lang {
	return Lang{
		name: 'V'
		lang_extensions: ['v', 'vsh']
		line_comments: '//'
		mline_comments: ['/*', '*/']
		string_start: ['"', "'"]
		color: '#5d87bd'
		keywords: [
			'break',
			'const',
			'continue',
			'defer',
			'else',
			'enum',
			'fn',
			'for',
			'go',
			'goto',
			'if',
			'import',
			'in',
			'interface',
			'match',
			'module',
			'none',
			'or',
			'pub',
			'return',
			'struct',
			'spawn',
			'type',
			'mut',
			'true',
			'false',
		]
	}
}
