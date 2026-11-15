#!/bin/sh
set -eu

if [ ! -x ./gitly ]; then
	sassc static/css/gitly.scss > static/css/gitly.css
	v -d sqlite -o gitly .
fi

GITLY_SQLITE_PATH="${GITLY_SQLITE_PATH:-./gitly.sqlite}" exec ./gitly "$@"
