module highlight

fn init_go() Lang {
	return Lang{
		name: 'Go'
		lang_extensions: ['go']
		line_comments: '//'
		mline_comments: ['/*', '*/']
		string_start: ['"', '`']
		color: '#00add8'
		keywords: [
			'break',
			'chan',
			'const',
			'continue',
			'complex64',
			'complex128',
			'defer',
			'else',
			'func',
			'for',
			'fallthrough',
			'go',
			'goto',
			'if',
			'import',
			'interface',
			'iota',
			'nil',
			'package',
			'range',
			'return',
			'switch',
			'struct',
			'type',
			'bool',
			'string',
			'int',
			'int8',
			'int16',
			'int8',
			'int64',
			'byte',
			'uint8',
			'uint16',
			'uint32',
			'uint64',
			'rune',
			'float32',
			'float64',
		]
	}
}
