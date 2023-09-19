//#include "stdint.h"

#flag darwin -I/opt/homebrew/include
#flag darwin -L/opt/homebrew/lib

#flag darwin -lgit2

#include "git2/types.h"
#include "git2/common.h"
#include "git2/global.h"
#include "git2/repository.h"

#include "git2.h"

fn C.git_libgit2_init()
fn C.git_libgit2_shutdown()
fn C.git_repository_init(repo voidptr, path &char, is_bare bool) int

fn C.git_libgit2_features()
fn C.git_commit_lookup(voidptr, voidptr, &C.git_oid) int

struct C.git_repository {}

struct C.git_commit {}

struct C.git_oid {}

fn C.git_commit_message(voidptr) &char

fn init() {
	C.git_libgit2_init()
}

fn shutdown() {
	C.git_libgit2_shutdown()
}

struct Repo {
	obj &C.git_repository

	path string
}

fn (r Repo) str() string {
	return 'Repo{ path:${r.path} }'
}

fn (r Repo) log() {
	oid := C.git_oid{}
	commit := &C.git_commit(unsafe { nil })
	ret := C.git_commit_lookup(&commit, r.obj, &oid)
	println(ret)
	s := C.git_commit_message(commit)
	q := cstring_to_vstring(s)
	println(q)
}

fn new_repo(path string) Repo {
	x := &C.git_repository(unsafe { nil })
	ret := C.git_repository_init(&x, path.str, false)
	println('ff ${ret}')
	return Repo{
		obj: x
		path: path
	}
}

fn main() {
	r := new_repo('/tmp/v')
	r.log()
	C.git_libgit2_features()
	println(r)
}
