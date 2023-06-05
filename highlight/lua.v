module highlight

fn init_lua() Lang {
	return Lang{
		name: 'Lua'
		lang_extensions: ['lua']
		line_comments: '--'
		mline_comments: ['--[[', ']]']
		string_start: ['"', "'"]
		color: '#00007d'
		keywords: [
			'and',
			'break',
			'do',
			'else',
			'elseif',
			'end',
			'false',
			'for',
			'function',
			'goto',
			'if',
			'in',
			'local',
			'nil',
			'not',
			'or',
			'repeat',
			'return',
			'then',
			'true',
			'until',
			'while',
		]
	}
}
