module highlight

fn init_ts() Lang {
	return Lang{
		name: 'TypeScript'
		lang_extensions: ['ts', 'tsx']
		line_comments: '//'
		mline_comments: ['/*', '*/']
		string_start: ['"', "'"]
		color: '#2b7489'
		keywords: [
			'any',
			'as',
			'boolean',
			'break',
			'case',
			'catch',
			'const',
			'continue',
			'do',
			'else',
			'enum',
			'export',
			'extends',
			'finally',
			'for',
			'function',
			'get',
			'if',
			'implements',
			'in',
			'instanceof',
			'interface',
			'let',
			'module',
			'new',
			'null',
			'number',
			'package',
			'private',
			'public',
			'return',
			'static',
			'string',
			'super',
			'switch',
			'this',
			'throw',
			'try',
			'type',
			'typeof',
			'var',
			'void',
			'while',
			'yield',
			'false',
			'true',
		]
	}
}
