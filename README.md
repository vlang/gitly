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

- Multiple users and multiple repos
- `git push`
- Access via ssh
- Pull requests

```sh
sassc static/css/gitly.scss > static/css/gitly.css
v .
./gitly
```

If you don't want to install `sassc`, you can simply run
```
wget -O static/css/gitly.css https://gitly.org/gitly.css
```

Required dependencies:
* V 0.1.28.1 (https://vlang.io)
* SQLite (Ubuntu/Debian: `libsqlite3-dev`)
* Markdown (`v install markdown`)
* sassc

Gitly will support Postgres and MySQL in the future (once V ORM does).

![](https://user-images.githubusercontent.com/687996/85933714-b195fe80-b8da-11ea-9ddd-09cadc2103e4.png)


## Contributing
GitHub contributing docs (https://docs.github.com/en/github/collaborating-with-issues-and-pull-requests/github-flow)

Example workflow:
1. Fork the project
1. Add your feature
1. Create a branch `git branch YOUR-FEATURE-TITLE`
1. Checkout the branch `git checkout YOUR-FEATURE-TITLE`
1. Add your features to the head `git add .`
1. Commit your features `git commit -m "edit message"`
1. Add your fork as remote `git remote add fork LINK-TO-THE-FORK-REPO`
1. Push it to your fork `git push --set-upstream fork YOUR-FEATURE-TITLE`

Then create a pull request (https://docs.github.com/en/github/collaborating-with-issues-and-pull-requests/creating-a-pull-request)
GitHub Flow (https://guides.github.com/introduction/git-handbook/#github)

We want the code as simple as possible. And please use the present tense and small case for the commit messages and the pull request title.
