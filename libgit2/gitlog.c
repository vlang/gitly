#include <stdio.h>
#include "git2.h"

int main() {
git_libgit2_init();

git_repository *repo = NULL;
git_repository_init(&repo, "/tmp/v", 0);

git_oid oid;
git_reference_name_to_id(&oid, repo, "HEAD");

git_commit *commit = NULL;
git_commit_lookup(&commit, repo, &oid);

git_revwalk *walker = NULL;
git_revwalk_new(&walker, repo);
git_revwalk_push(walker, &oid);

git_oid current_oid;
int i = 0;
while (git_revwalk_next(&current_oid, walker) == 0) {
	i++;
	if (i > 10) {break;}
git_commit_lookup(&commit, repo, &current_oid);
const git_signature *author = git_commit_author(commit);

printf("Commit ID: %s\n", git_oid_tostr_s(&current_oid));
printf("Author: %s <%s>\n", author->name, author->email);
printf("Message: %s\n\n", git_commit_message(commit));
}

git_revwalk_free(walker);
git_commit_free(commit);
git_repository_free(repo);
git_libgit2_shutdown();

return 0;
}
