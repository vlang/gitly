module highlight

fn init_c() Lang {
	return Lang{
		name: 'C'
		lang_extensions: ['c']
		line_comments: '//'
		mline_comments: ['/*', '*/']
		string_start: ['"', "'"]
		color: '#555555'
		keywords: [
			'auto',
			'double',
			'int',
			'struct',
			'break',
			'else',
			'long',
			'switch',
			'case',
			'enum',
			'register',
			'typedef',
			'char',
			'extern',
			'return',
			'union',
			'const',
			'float',
			'short',
			'unsigned',
			'continue',
			'for',
			'signed',
			'void',
			'default',
			'goto',
			'sizeof',
			'volatile',
			'do',
			'if',
			'static',
			'while',
			'#if',
			'#else',
			'#elif',
			'#endif',
			'#define',
			'#undef',
			'#warning',
			'#error',
			'#line',
			'#pragma',
			'#ifdef',
			'#ifndef',
			'#include',
		]
	}
}
