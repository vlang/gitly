// Designed for Java 5.0+
module highlight

fn init_js() Lang {
	return Lang{
		name: 'Java'
		lang_extensions: ['java']
		line_comments: '//'
		mline_comments: ['/*', '*/']
		string_start: ['"', "'"]
		color: '#f1e05a'
		keywords: [
			'abstract',
			'continue',
			'for',
			'new',
			'switch',
			'assert',
			'default',
			'goto',
			'package',
			'synchronized',
			'boolean',
			'do',
			'if',
			'private',
			'this',
			'break',
			'double',
			'implements',
			'protected',
			'throw',
			'byte',
			'else',
			'import',
			'public',
			'throws',
			'case',
			'enum',
			'instanceof',
			'return',
			'transient',
			'catch',
			'extends',
			'int',
			'short',
			'try',
			'char',
			'final',
			'interface',
			'static',
			'void',
			'class',
			'finally',
			'long',
			'strictfp',
			'volatile',
			'const',
			'float',
			'native',
			'super',
			'while',
		]
	}
}
