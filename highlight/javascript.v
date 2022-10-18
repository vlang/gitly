module highlight

fn init_js() Lang {
	return Lang{
		name: 'JavaScript'
		lang_extensions: ['js', 'mjs', 'jsx']
		line_comments: '//'
		mline_comments: ['/*', '*/']
		string_start: ['"', "'"]
		color: '#f1e05a'
		keywords: [
			'break',
			'do',
			'instanceof',
			'typeof',
			'case',
			'else',
			'new',
			'var',
			'catch',
			'finally',
			'return',
			'void',
			'continue',
			'for',
			'switch',
			'while',
			'debugger',
			'function',
			'this',
			'with',
			'default',
			'if',
			'throw',
			'delete',
			'in',
			'of',
			'try',
			'as',
			'let',
			'const',
			'import',
			'export',
			'yield',
			'false',
			'true',
		]
	}
}
