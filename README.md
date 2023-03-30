<p align="left">
  <h1> Gitly <img src="https://cdn-icons-png.flaticon.com/512/4500/4500935.png" width="50px" /> </h1>
</p>

GitHub/GitLab alternative written in V. **|** [Demo here](https://gitly.org) **|** ![CI](https://github.com/vlang/gitly/workflows/CI/badge.svg?branch=master) **|** Version: **This is pre-alpha software**
![](https://user-images.githubusercontent.com/687996/85933714-b195fe80-b8da-11ea-9ddd-09cadc2103e4.png)



## Intro
The V web framework and Gitly are at an early stage of development. Lots of features are missing. The biggest missing features that will be implemented soon:

- [x] Multiple users and multiple repos
- [x] `git push`
- [ ] Access via ssh
- [ ] Pull requests
- [ ] Gitly will support Postgres and MySQL in the future (once V ORM does).

```sh
sassc static/css/gitly.scss > static/css/gitly.css
v .
./gitly
```

If you don't want to install `sassc`, you can simply run

```
curl https://gitly.org/css/gitly.css --output static/css/gitly.css
```

## Features
- Light and fast
- Minimal amount of RAM usage (works great on the cheapest $3.5 AWS Lightsail instance)
- Easy to deploy (a single <1 MB binary that includes compiled templates)
- Works without JavaScript
- Detailed language stats for each directory
- "Top files" feature to give an overview of the project

## Required dependencies
* V 0.1.28.1 (https://vlang.io)
* SQLite (Ubuntu/Debian: `libsqlite3-dev`)
* Markdown (`v install markdown`)
* PCRE (`v install pcre`)
* sassc
