module main

import veb

@['/:username/feed']
pub fn (mut app App) user_feed_default(mut ctx Context, username string) veb.Result {
	return app.user_feed(mut ctx, username, 0)
}

@['/:username/feed/:page']
pub fn (mut app App) user_feed(mut ctx Context, username string, page int) veb.Result {
	exists, user := app.check_username(username)

	if !exists || ctx.user.username != user.username {
		return ctx.not_found()
	}

	user_id := ctx.user.id
	item_count := app.get_feed_items_count(user_id)
	offset := feed_items_per_page * page
	page_count := calculate_pages(item_count, feed_items_per_page)
	is_first_page := check_first_page(page)
	is_last_page := check_last_page(item_count, offset, feed_items_per_page)
	prev_page, next_page := generate_prev_next_pages(page)

	feed := app.build_user_feed_as_page(user_id, offset)
	mut items_start_day_group := []int{}
	mut last_unique_date := ''

	for item in feed {
		item_ymmdd := item.created_at.ymmdd()

		if item_ymmdd != last_unique_date {
			items_start_day_group << item.id

			last_unique_date = item_ymmdd
		}
	}

	return $veb.html()
}
