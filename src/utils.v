module main

import time
import math
import os

pub fn (mut app App) running_since() string {
	duration := time.now().unix - app.started_at

	seconds_in_hour := 60 * 60

	days := int(math.floor(duration / (seconds_in_hour * 24)))
	hours := int(math.floor(duration / seconds_in_hour % 24))
	minutes := int(math.floor(duration / 60)) % 60
	seconds := duration % 60

	return '${days} days ${hours} hours ${minutes} minutes and ${seconds} seconds'
}

pub fn (mut app App) make_path(branch_name string, i int) string {
	if i == 0 {
		return app.path_split[..i + 1].join('/')
	}

	mut s := app.path_split[0]

	s += '/tree/${branch_name}/'
	s += app.path_split[1..i + 1].join('/')

	return s
}

fn create_directory_if_not_exists(path string) {
	if !os.exists(path) {
		os.mkdir(path) or { panic('cannot create ${path} directory') }
	}
}

fn calculate_pages(count int, per_page int) int {
	if count == 0 {
		return 0
	}

	return int(math.ceil(f32(count) / f32(per_page))) - 1
}

fn generate_prev_next_pages(page int) (int, int) {
	prev_page := if page > 0 { page - 1 } else { 0 }
	next_page := page + 1

	return prev_page, next_page
}

fn check_first_page(page int) bool {
	return page == 0
}

fn check_last_page(total int, offset int, per_page int) bool {
	return (total - offset) < per_page
}
