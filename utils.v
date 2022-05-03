module main

import time
import math

pub fn (mut app App) running_since() string {
	duration := time.now().unix - app.started_at

	seconds_in_hour := 60 * 60

	days := int(math.floor(duration / (seconds_in_hour * 24)))
	hours := int(math.floor(duration / seconds_in_hour % 24))
	minutes := int(math.floor(duration / 60)) % 60
	seconds := duration % 60

	return '$days days $hours hours $minutes minutes and $seconds seconds'
}

pub fn (mut app App) make_path(i int) string {
	if i == 0 {
		return app.path_split[..i + 1].join('/')
	}

	mut s := app.path_split[0]

	s += '/tree/$app.branch/'
	s += app.path_split[1..i + 1].join('/')

	return s
}
