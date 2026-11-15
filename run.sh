#!/bin/sh
set -eu

if [ ! -x ./gitly ]; then
	sassc static/css/gitly.scss > static/css/gitly.css
	v .
fi

exec ./gitly "$@"
