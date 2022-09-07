module main

import time

fn (app App) add_activity(user_id int, name string) {
	activity := Activity{
		user_id: user_id
		name: name
		created_at: time.now()
	}

	sql app.db {
		insert activity into Activity
	}
}

fn (mut app App) find_activities(user_id int) []Activity {
	return sql app.db {
		select from Activity where user_id == user_id order by created_at desc
	}
}

fn (mut app App) has_activity(user_id int, name string) bool {
	activity_count := sql app.db {
		select count from Activity where user_id == user_id && name == name
	}

	return activity_count > 0
}
