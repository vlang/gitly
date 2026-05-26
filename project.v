// Copyright (c) 2019-2026 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by a GPL license that can be found in the LICENSE file.
module main

import time
import veb

struct Project {
	id int @[primary; sql: serial]
mut:
	repo_id     int
	name        string
	description string
	created_at  int
}

struct ProjectColumn {
	id int @[primary; sql: serial]
mut:
	project_id int
	name       string
	position   int
}

struct ProjectCard {
	id int @[primary; sql: serial]
mut:
	column_id  int
	title      string
	note       string
	position   int
	issue_id   int // 0 if a free-form note
	created_at int
}

fn (p &Project) formatted_name() veb.RawHtml {
	return html_escape_text(p.name)
}

fn (mut app App) add_project(repo_id int, name string, description string) !int {
	pr := Project{
		repo_id:     repo_id
		name:        name
		description: description
		created_at:  int(time.now().unix())
	}
	sql app.db {
		insert pr into Project
	}!
	project_id := db_last_insert_id(mut app.db)
	if project_id != 0 {
		for i, col_name in ['Todo', 'In progress', 'Done'] {
			app.add_project_column(project_id, col_name, i) or {}
		}
	}
	return project_id
}

fn (mut app App) list_repo_projects(repo_id int) []Project {
	return sql app.db {
		select from Project where repo_id == repo_id order by id desc
	} or { []Project{} }
}

fn (mut app App) find_project(id int) ?Project {
	rows := sql app.db {
		select from Project where id == id limit 1
	} or { []Project{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) delete_project(id int) ! {
	cols := app.list_project_columns(id)
	for col in cols {
		sql app.db {
			delete from ProjectCard where column_id == col.id
		}!
	}
	sql app.db {
		delete from ProjectColumn where project_id == id
	}!
	sql app.db {
		delete from Project where id == id
	}!
}

fn (mut app App) delete_repo_projects(repo_id int) ! {
	prs := app.list_repo_projects(repo_id)
	for pr in prs {
		app.delete_project(pr.id) or {}
	}
}

fn (mut app App) add_project_column(project_id int, name string, position int) !int {
	c := ProjectColumn{
		project_id: project_id
		name:       name
		position:   position
	}
	sql app.db {
		insert c into ProjectColumn
	}!
	return db_last_insert_id(mut app.db)
}

fn (mut app App) list_project_columns(project_id int) []ProjectColumn {
	return sql app.db {
		select from ProjectColumn where project_id == project_id order by position
	} or { []ProjectColumn{} }
}

fn (mut app App) find_project_column(id int) ?ProjectColumn {
	rows := sql app.db {
		select from ProjectColumn where id == id limit 1
	} or { []ProjectColumn{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) delete_project_column(id int) ! {
	sql app.db {
		delete from ProjectCard where column_id == id
	}!
	sql app.db {
		delete from ProjectColumn where id == id
	}!
}

fn (mut app App) add_project_card(column_id int, title string, note string) ! {
	pos := sql app.db {
		select count from ProjectCard where column_id == column_id
	} or { 0 }
	c := ProjectCard{
		column_id:  column_id
		title:      title
		note:       note
		position:   pos
		created_at: int(time.now().unix())
	}
	sql app.db {
		insert c into ProjectCard
	}!
}

fn (mut app App) list_project_cards(column_id int) []ProjectCard {
	return sql app.db {
		select from ProjectCard where column_id == column_id order by position
	} or { []ProjectCard{} }
}

fn (mut app App) find_project_card(id int) ?ProjectCard {
	rows := sql app.db {
		select from ProjectCard where id == id limit 1
	} or { []ProjectCard{} }
	if rows.len == 0 {
		return none
	}
	return rows.first()
}

fn (mut app App) move_project_card(card_id int, new_column_id int) ! {
	sql app.db {
		update ProjectCard set column_id = new_column_id where id == card_id
	}!
}

fn (mut app App) delete_project_card(id int) ! {
	sql app.db {
		delete from ProjectCard where id == id
	}!
}
