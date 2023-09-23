#include <stdio.h>
#include <git2.h>
#include <string.h>

int main() {
    git_libgit2_init();

    const char* repo_path = "/Users/alex/code/gitly/repos/admin/vlang2";
    const char* file_path = "README.md";
    const char* branch_name = "master";

    git_repository* repo = NULL;
    git_reference* branch_ref = NULL;
    git_object* treeish = NULL;
    git_blob* blob = NULL;

    int error = git_repository_open(&repo, repo_path);
    if (error != 0) {
        printf("Failed to open the repository: %s\n", git_error_last()->message);
        return 1;
    }

    error = git_branch_lookup(&branch_ref, repo, branch_name, GIT_BRANCH_LOCAL);
    if (error != 0) {
        printf("Failed to lookup branch: %s\n", git_error_last()->message);
        return 1;
    }

    error = git_reference_peel(&treeish, branch_ref, GIT_OBJECT_COMMIT);
    if (error != 0) {
        printf("Failed to peel reference to commit: %s\n", git_error_last()->message);
        return 1;
    }

    const git_commit* commit = (const git_commit*)treeish;
    error = git_commit_tree(&treeish, commit);
    if (error != 0) {
        printf("Failed to get commit tree: %s\n", git_error_last()->message);
        return 1;
    }

    git_tree* tree = (git_tree*)treeish;

    // Iterate through the tree entries to find the file
    int entry_count = git_tree_entrycount(tree);
    for (int i = 0; i < entry_count; i++) {
        const git_tree_entry* entry = git_tree_entry_byindex(tree, i);
        const char* entry_name = git_tree_entry_name(entry);

        if (strcmp(entry_name, file_path) == 0) {
            // Found the file
            error = git_blob_lookup(&blob, repo, git_tree_entry_id(entry));
            if (error != 0) {
                printf("Failed to lookup blob: %s\n", git_error_last()->message);
                return 1;
            }

            const char* content = git_blob_rawcontent(blob);
            size_t size = git_blob_rawsize(blob);

            printf("Content of %s (from branch %s):\n", file_path, branch_name);
            fwrite(content, 1, size, stdout);

            git_blob_free(blob);
            break;
        }
    }

    git_object_free(treeish);
    git_reference_free(branch_ref);
    git_repository_free(repo);

    git_libgit2_shutdown();
    return 0;
}

