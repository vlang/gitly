module git

// import time

//#include "stdint.h"

#flag darwin -I/opt/homebrew/include
#flag darwin -L/opt/homebrew/lib

#flag linux -I/usr/local/include
#flag linux -L/usr/local/lib

#flag -lgit2

// #flag windows -Igit/

#include "git2/types.h"
#include "git2/common.h"
#include "git2/global.h"
#include "git2/repository.h"

#include "git2.h"

fn C.git_libgit2_init()
fn C.git_libgit2_shutdown()
fn C.git_repository_init(repo voidptr, path &char, is_bare bool) int
fn C.git_repository_open(repo voidptr, path &char) int

fn C.git_libgit2_features()
fn C.git_commit_lookup(voidptr, voidptr, &C.git_oid) int

fn C.git_repository_free(repo &C.git_repository)
fn C.git_repository_head(out &&C.git_reference, repo &C.git_repository) int

fn C.git_reference_free(ref &C.git_reference)

struct C.git_repository {}

struct C.git_commit {}

struct C.git_signature {
	name  &char
	email &char
}

struct C.git_oid {}

struct C.git_reference {}

struct C.git_revwalk {}

struct C.git_object {}

struct C.git_error {
	message &char
}

@[typedef]
struct C.git_tree_entry {}

struct C.git_clone_options {
mut:
	bare int
}

fn C.git_commit_message(voidptr) &char
fn C.git_reference_lookup(&&C.git_reference, &C.git_repository, &char)
fn C.git_reference_symbolic_target(&C.git_reference) &char
fn C.git_revwalk_next(&C.git_oid, &C.git_revwalk) int
fn C.git_revwalk_new(&&C.git_revwalk, &C.git_repository) int
fn C.git_revwalk_push(&C.git_revwalk, &C.git_oid) int
fn C.git_reference_name_to_id(&C.git_oid, &C.git_repository, &char)
fn C.git_oid_tostr_s(&C.git_oid) &char
fn C.git_commit_author(&C.git_commit) &C.git_signature
fn C.git_branch_lookup(&&C.git_reference, &C.git_repository, &char, int) int
fn C.git_error_last() &C.git_error
fn C.git_reference_peel(&&C.git_object, &C.git_reference, int) int

// fn C.git_commit_tree(&&C.git_tree, &C.git_commit)
fn C.git_commit_tree(voidptr, &C.git_commit)
fn C.git_tree_entrycount(&C.git_tree) int
fn C.git_tree_entry_byindex(&C.git_tree, int) &C.git_tree_entry
fn C.git_tree_entry_name(&C.git_tree_entry) &char
fn C.git_blob_lookup(&&C.git_blob, &C.git_repository, &C.git_oid) int
fn C.git_tree_entry_id(&C.git_tree_entry) &C.git_oid
fn C.git_blob_rawcontent(&C.git_blob) voidptr
fn C.git_blob_rawsize(&C.git_blob) int
fn C.git_blob_free(&C.git_blob)
fn C.git_clone(&&C.git_repository, &char, &char, &C.git_clone_options) int
fn C.git_clone_options_init(&C.git_clone_options, int)

fn C.git_object_lookup_bypath(&&C.git_object, &C.git_object, &char, int) int
fn C.git_object_peel(&&C.git_object, &C.git_object, int) int
fn C.git_object_id(&C.git_object) &C.git_oid

fn init() {
	C.git_libgit2_init()
}

fn shutdown() {
	C.git_libgit2_shutdown()
}

pub struct Repo {
	obj &C.git_repository = unsafe { nil }

	path string
}

fn (r Repo) str() string {
	return 'Repo{ path:${r.path} }'
}

@[params]
struct LogParams {
	n      int
	dir    string // -C "dir"
	branch string
}

struct Commit {
mut:
	msg          string
	hash         string
	author_name  string
	author_email string
}

fn (r Repo) log(p LogParams) []Commit {
	oid := C.git_oid{}
	C.git_reference_name_to_id(&oid, r.obj, c'HEAD')
	commit := &C.git_commit(unsafe { nil })
	walker := &C.git_revwalk(unsafe { nil })
	if C.git_revwalk_new(&walker, r.obj) != 0 {
		println('failed to create walker')
		return []
	}
	C.git_revwalk_push(walker, &oid)
	mut commits := []Commit{cap: 10}
	mut i := 0
	mut cur_oid := C.git_oid{}
	for C.git_revwalk_next(&cur_oid, walker) == 0 {
		mut gitly_commit := Commit{}
		// println('RET =${ret0}')
		// println(C.GIT_ITEROVER)
		C.git_commit_lookup(&commit, r.obj, &cur_oid)
		// Get commit message
		msg := C.git_commit_message(commit)
		// Get commit id (hash)
		commit_id := C.git_oid_tostr_s(&cur_oid)
		// Get commit author
		author := C.git_commit_author(commit)
		unsafe {
			if msg == nil || commit_id == nil || author == nil || author.name == nil {
				println('nil log, skipping')
				continue
			}
		}
		gitly_commit.msg = unsafe { cstring_to_vstring(msg) }
		gitly_commit.hash = unsafe { cstring_to_vstring(commit_id) }
		gitly_commit.author_name = unsafe { cstring_to_vstring(author.name) }
		gitly_commit.author_email = unsafe { cstring_to_vstring(author.email) }
		println(gitly_commit)
		commits << gitly_commit

		i++
		if p.n > 0 && i >= p.n {
			// Reached the limit `n` (like `git log -n10`)
			break
		}
	}
	return commits
}

pub fn new_repo(path string) &Repo {
	repo_obj := &C.git_repository(unsafe { nil })
	// ret := C.git_repository_init(&repo_obj, path.str, false)
	ret := C.git_repository_open(&repo_obj, path.str)
	println('ff ${ret}')
	// git_reference_free(head_ref);
	return &Repo{
		obj:  repo_obj
		path: path
	}
}

pub fn (r &Repo) current_branch() string {
	head_ref := &C.git_reference(unsafe { nil })
	C.git_reference_lookup(&head_ref, r.obj, c'HEAD')
	symbolic_ref := C.git_reference_symbolic_target(head_ref)
	branch := unsafe { cstring_to_vstring(symbolic_ref) }
	return branch.after('refs/heads/')
}

pub fn (repo &Repo) primary_branch() string {
	err := C.git_repository_open(&repo.obj, repo.path.str)
	if err != 0 {
		return ''
	}
	defer {
		C.git_repository_free(repo.obj)
	}

	// Get HEAD reference
	head_ref := &C.git_reference(unsafe { nil })
	err_head := C.git_repository_head(&head_ref, repo.obj)
	if err_head != 0 {
		return ''
	}
	defer {
		C.git_reference_free(head_ref)
	}

	// Get symbolic target
	symbolic_ref := C.git_reference_symbolic_target(head_ref)
	if symbolic_ref == unsafe { nil } {
		return ''
	}

	// Convert to V string and extract branch name
	branch := unsafe { cstring_to_vstring(symbolic_ref) }
	return get_branch_name_from_reference(branch)
}

fn get_branch_name_from_reference(ref string) string {
	return ref.after('refs/heads/')
}

pub fn (r &Repo) show_file_blob(branch string, file_path string) !string {
	mut blob := &C.git_blob(unsafe { nil })
	mut branch_ref := &C.git_reference(unsafe { nil })
	if C.git_branch_lookup(&branch_ref, r.obj, branch.str, C.GIT_BRANCH_LOCAL) != 0 {
		C.printf(c'Failed to lookup branch: %s\n', C.git_error_last().message)
		return error('sdf')
	}

	mut treeish := &C.git_object(unsafe { nil })
	if C.git_reference_peel(&treeish, branch_ref, C.GIT_OBJECT_COMMIT) != 0 {
		C.printf(c'Failed to peel reference to commit: %s\n', C.git_error_last().message)
		return error('sdf')
	}

	commit := &C.git_commit(treeish)
	C.git_commit_tree(&treeish, commit)
	if commit == unsafe { nil } {
		C.printf(c'Failed to get commit tree\n')
		return error('sdf')
	}
	// create file object
	mut file_obj := &C.git_object(unsafe { nil })

	// get file object
	if C.git_object_lookup_bypath(&file_obj, treeish, file_path.str, C.GIT_OBJECT_BLOB) != 0 {
		C.printf(c'Failed to lookup file: %s\n', C.git_error_last().message)
		return error('sdf')
	}

	// get file oid
	mut oid := C.git_object_id(file_obj)

	// get blob object
	if C.git_blob_lookup(&blob, r.obj, oid) != 0 {
		C.printf(c'Failed to lookup blob: %s\n', C.git_error_last().message)
		return error('sdf')
	}

	// get blob content
	content := C.git_blob_rawcontent(blob)
	// size := C.git_blob_rawsize(blob)

	C.printf(c'Content of %s (from branch %s):\n', file_path.str, branch.str)

	text := unsafe { cstring_to_vstring(content) }
	C.git_blob_free(blob)
	return text

}

pub fn clone(url string, path string) {
	mut r := new_repo(path)
	r.clone(url, path)
}

pub fn (mut r Repo) clone(url string, path string) {
	println('new clone url="${url}" path="${path}"')
	// Clone options
	mut clone_opts := C.git_clone_options{} //( unsafe{nil})
	C.git_clone_options_init(&clone_opts, C.GIT_CLONE_OPTIONS_VERSION)

	// Set the bare flag to create a bare repository
	clone_opts.bare = 1

	// Clone the repository
	// r.git_repo = &C.git_repository(unsafe { nil })
	ret := C.git_clone(&r.obj, url.str, path.str, &clone_opts)
	if ret != 0 {
		C.printf(c'Failed to clone: %s\n', C.git_error_last().message)
	} else {
		println('Bare repository cloned successfully!\n')
	}
}

/*
fn main() {
	t0 := time.now()
	r := new_repo('/Users/alex/code/gitly/repos/admin/vlang2')
	/*
	println(time.since(t0))
	println('1current branch=')
	b := r.current_branch()
	println(b)
	t := time.now()
	r.log(n: 10)
	println(time.since(t))
	*/
	println('GIT SHOW')

	t := time.now()
	println(r.show_file_blob('master', 'README.md')!)
	println(time.since(t))
	C.git_libgit2_features()
	println(r)
}
*/
