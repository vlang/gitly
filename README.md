# gitly
![CI](https://github.com/vlang/gitly2/workflows/CI/badge.svg?branch=master)

GitHub/GitLab alternative written in V.


https://gitly.org

- Light and fast
- Minimal amount of RAM usage (works great on the cheapest $3.5 AWS Lightsail instance)
- Easy to deploy (a single <1 MB binary that includes compiled templates)
- Works without JavaScript
- Detailed language stats for each directory
- "Top files" feature to give an overview of the project 

** This is pre-alpha software **

The V web framework and Gitly are at an early stage of development. Lots of features are missing.
The biggest missing features that will be implemented soon:

- Multiple users and multiple repos
- `git push`
- Access via ssh
- Pull requests


```sh
git clone https://github.com/vlang/v test_repo # Clone the test/demo repo
# Compile the `gitly.scss` file to `gitly.css`
sassc static/css/gitly.scss > static/css/gitly.css
v .
./gitly
```
Required dependencies:
* V 0.1.28.1
* SQLite (Ubuntu/Debian: `libsqlite3-dev`)
* sassc

![](https://camo.githubusercontent.com/fe09cea06fef5481c49d6d0e0eb5dd6e426ef1a7/68747470733a2f2f7765622e617263686976652e6f72672f7765622f3230313730333130313334363230696d5f2f68747470733a2f2f6769746c792e696f2f696d672f6c702d73637265656e302e706e67)



