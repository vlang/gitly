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

**This is alpha software**

The V web framework and Gitly are at an early stage of development. Lots of features are missing.
The biggest missing features that will be implemented soon:

- [x] Multiple users and multiple repos
- [x] `git push`
- [ ] Access via ssh
- [ ] Pull requests

```sh
sassc src/static/css/gitly.scss > src/static/css/gitly.css
v .
./gitly
```

If you don't want to install `sassc`, you can simply run

```
curl https://gitly.org/css/gitly.css --output static/css/gitly.css
```


Required dependencies:
* V 0.4.2 93ff40a (https://vlang.io)
* SQLite (Ubuntu/Debian: `libsqlite3-dev`)
* Markdown (`v install markdown`)
* PCRE (`v install pcre`)
* sassc
* libgit2

You can install libgit2 with:
  * Ubuntu/Debian: `apt install libgit2-dev`
  * FreeBSD: `pkg install libgit2`
  * macOS: `brew install libgit2`


Gitly will support Postgres and MySQL in the future (once V ORM does).

![](https://user-images.githubusercontent.com/687996/85933714-b195fe80-b8da-11ea-9ddd-09cadc2103e4.png)
