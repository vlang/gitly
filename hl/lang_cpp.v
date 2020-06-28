module hl

fn init_cpp() Lang {
	return Lang{
		name: 'C++'
		lang_extensions: ['cpp', 'cc', 'hh', 'h']
		line_comments: '//'
		mline_comments: ['/*', '*/']
		string_start: ['"', "\'"]
		color: '#f34b7d'
		keywords: ['int', 'float', 'while', 'private', 'char', 'catch', 'export', 'virtual', 'operator',
			'sizeof', 'typedef', 'const', 'struct', 'for', 'static_cast', 'union', 'namespace', 'unsigned',
			'long', 'volatile', 'static', 'protected', 'bool', 'template', 'mutable', 'if', 'public', 'friend',
			'do', 'goto', 'auto', 'void', 'enum', 'else', 'break', 'extern', 'using', 'class', 'asm',
			'case', 'typeid', 'short', 'default', 'double', 'register', 'explicit', 'signed', 'typename', 'try',
			'this', 'switch', 'continue', 'inline', 'delete', 'alignof', 'constexpr', 'decltype', 'noexcept',
			'static_assert', 'thread_local', 'restrict', '_Bool', 'complex', 'return', 'throw', 'new', 'true',
			'false', 'nullptr', '#if', '#else', '#elif', '#endif', '#define', '#undef', '#warning',
			'#error', '#line', '#pragma', '#ifdef', '#ifndef', '#include', '#endif']
	}
}
