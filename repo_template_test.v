module main

fn test_english_count_uses_plural_for_twenty_one() {
	forms := ['issue', 'issues', 'issues']

	assert pick_plural_form(1, forms, .en) == 'issue'
	assert pick_plural_form(21, forms, .en) == 'issues'
	assert pick_plural_form(121, forms, .en) == 'issues'
}

fn test_russian_count_keeps_three_form_plural_rules() {
	forms := ['one', 'few', 'many']

	assert pick_plural_form(1, forms, .ru) == 'one'
	assert pick_plural_form(2, forms, .ru) == 'few'
	assert pick_plural_form(5, forms, .ru) == 'many'
	assert pick_plural_form(11, forms, .ru) == 'many'
	assert pick_plural_form(21, forms, .ru) == 'one'
}

fn test_polish_repository_counts_use_one_few_and_many_forms() {
	for count, expected in {
		0:   'zgłoszeń'
		1:   'zgłoszenie'
		2:   'zgłoszenia'
		4:   'zgłoszenia'
		5:   'zgłoszeń'
		11:  'zgłoszeń'
		12:  'zgłoszeń'
		14:  'zgłoszeń'
		21:  'zgłoszeń'
		22:  'zgłoszenia'
		25:  'zgłoszeń'
		101: 'zgłoszeń'
		112: 'zgłoszeń'
		122: 'zgłoszenia'
		-1:  'zgłoszenie'
		-2:  'zgłoszenia'
		-5:  'zgłoszeń'
		-21: 'zgłoszeń'
	} {
		assert string(format_count(count, 'issues_count', .pl)) == '<b>${count}</b> ${expected}'
	}
}

fn test_german_repository_counts_use_plural_except_for_one() {
	assert string(format_count(0, 'issues_count', .de)) == '<b>0</b> Issues'
	assert string(format_count(1, 'issues_count', .de)) == '<b>1</b> Issue'
	assert string(format_count(2, 'issues_count', .de)) == '<b>2</b> Issues'
	assert string(format_count(21, 'issues_count', .de)) == '<b>21</b> Issues'
}
