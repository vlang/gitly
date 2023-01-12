# Gitly
![CI](https://github.com/vlang/gitly/workflows/CI/badge.svg?branch=master)

GitHub/GitLab alternative written in V.

https://gitly.org

- Light and fast
- Minimal amount of RAM usage (works great on the cheapest $3.5 AWS Lightsail instance)
- Easy to deploy (a single <1 MB binary that includes compiled templates)
- Works without JavaScript
- Detailed language stats for each directory
- "Top files" feature to give an overview of the project

**This is pre-alpha software**

The V web framework and Gitly are at an early stage of development. Lots of features are missing.
The biggest missing features that will be implemented soon:

- [x] Multiple users and multiple repos
- [x] `git push`
- [ ] Access via ssh
- [ ] Pull requests

```sh
cd src
v .
./gitly
```

If you want to use SCSS and have `sasscs` installed, run:
```
sassc src/static/css/gitly.scss > src/static/css/gitly.css
```

Required dependencies:
* V 0.1.28.1 (https://vlang.io)
* SQLite (Ubuntu/Debian: `libsqlite3-dev`)
* Markdown (`v install markdown`)
* sassc (optional)

Gitly will support Postgres and MySQL in the future (once V ORM does).

![](https://user-images.githubusercontent.com/687996/85933714-b195fe80-b8da-11ea-9ddd-09cadc2103e4.png)
