#!/usr/bin/env python3
"""Fault-inject production fakefs/task allocation sections; host test, not guest runtime."""
from pathlib import Path
import os,shutil,subprocess,sys,tempfile
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'ze-kernel-lock-tests';OUT.mkdir(exist_ok=True)
def read(p):return (ROOT/p).read_text(encoding='utf-8-sig')
def function(s,marker):
 a=s.index(marker);b=s.index('{',a);depth=1;i=b+1
 while depth:
  depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
fake=read('Vendor/ZeNative/ish/fs/fake.c');task=read('Vendor/ZeNative/ish/kernel/task.c')
functions='\n'.join(function(fake,'static int fakefs_'+op+'(') for op in ['unlink','rmdir','rename','mkdir'])
alloc=function(task,'struct task *task_create_(');a=alloc.index('    struct task *task = malloc(');b=alloc.index('    *task = (struct task) {}',a);alloc=alloc[a:b]
cleanup=function(task,'static void task_run_tlb_cleanup(')
header=r'''#define _DEFAULT_SOURCE
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#define PATH_MAX 4096
#define _EROFS -30
#define _EXDEV -18
#define FAKEFS_CHANGE_OP_UNLINK 1
#define FAKEFS_CHANGE_OP_RENAME 2
#define FAKEFS_CHANGE_OP_MKDIR 3
#define FAKEFS_CHANGE_OP_CREATE 4
#define FAKEFS_CHANGE_OP_WRITE 5
#define ERR_PTR(x) ((void *)(intptr_t)(x))
typedef unsigned mode_t_;
struct fakefs_db { int held; };
struct mount { struct fakefs_db fakefs; };
static struct mount fixture_mount;
static bool fixture_bind,fixture_hook,fixture_fail;
static int host_calls,txns;
static bool is_under_readonly_bind_mount(const char *p) {(void)p;return false;}
static bool is_under_bind_mount(const char *p) {(void)p;return fixture_bind;}
static bool bind_mount_translate_path_ex(const char *p,char *o,size_t n,bool *hook){(void)p;(void)n;strcpy(o,"host");*hook=fixture_hook;return fixture_bind;}
static void bind_mount_ensure_inode(struct fakefs_db *fs,struct mount *m,const char *p){(void)fs;(void)m;(void)p;}
static int errno_map(void){return -5;}
static int host_io(void){assert(!fixture_mount.fakefs.held);host_calls++;return fixture_fail?-1:0;}
static int fixture_unlink(const char *p){(void)p;return host_io();}
static int fixture_rmdir(const char *p){(void)p;return host_io();}
static int fixture_rename(const char *p,const char *q){(void)p;(void)q;return host_io();}
static int fixture_mkdir(const char *p,int mode){(void)p;(void)mode;return host_io();}
#define unlink fixture_unlink
#define rmdir fixture_rmdir
#define rename fixture_rename
#define mkdir fixture_mkdir
static void db_begin_write(struct fakefs_db *fs){assert(!fs->held);fs->held=1;txns++;}
static void db_commit(struct fakefs_db *fs){assert(fs->held);fs->held=0;}
static void db_rollback(struct fakefs_db *fs){db_commit(fs);}
static ino_t path_get_inode(struct fakefs_db *fs,const char *p){assert(fs->held);return !strcmp(p,"a")?1:2;}
static ino_t path_unlink(struct fakefs_db *fs,const char *p){(void)p;assert(fs->held);return 1;}
static void path_rename(struct fakefs_db *fs,const char *p,const char *q){(void)p;(void)q;assert(fs->held);}
struct ish_stat {int mode,uid,gid,rdev;};
static void path_create(struct fakefs_db *fs,const char *p,struct ish_stat *st){(void)p;(void)st;assert(fs->held);}
static void fakefs_record_change(const char *p,int op){(void)p;(void)op;}
static void inode_check_orphaned(struct mount *m,ino_t i){(void)m;(void)i;}
static int local_simple(struct mount *m,const char *p){(void)p;assert(m->fakefs.held);return 0;}
static int local_rename(struct mount *m,const char *p,const char *q){(void)q;return local_simple(m,p);}
static int local_mkdir(struct mount *m,const char *p,int mode){(void)mode;return local_simple(m,p);}
static struct {int (*fixture_unlink)(struct mount*,const char*);int (*fixture_rmdir)(struct mount*,const char*);int (*fixture_rename)(struct mount*,const char*,const char*);int (*fixture_mkdir)(struct mount*,const char*,int);}realfs={local_simple,local_simple,local_rename,local_mkdir};
#define S_IFDIR 0040000
struct mm {int marker;};
struct task { bool mm_release_deferred;struct mm *mm;void *mem;int general_lock;int euid,egid;};
static struct task *current;
static int pids_lock;
static void lock(int *p){assert(!*p);*p=1;}
static void unlock(int *p){assert(*p);*p=0;}
static bool released_mm;
static void mm_release(struct mm *m){assert(m);assert(current->mm==NULL && current->mem==NULL);assert(!current->general_lock);released_mm=true;}
struct tlb {int marker;};
static void tlb_free(struct tlb *t){(void)t;}
struct pid {int id;struct task *task;};
static struct pid pid_slot;
static void *fail_malloc(size_t n){(void)n;return NULL;}
'''
code=header+functions+'\n'+cleanup+'\n#define malloc fail_malloc\nstatic struct task *allocation_failure(void) { struct pid *pid=&pid_slot;\n'+alloc+'return task;\n}\n#undef malloc\n'
code+=r'''int main(void){
 struct task caller={.euid=1,.egid=2};current=&caller;
 for(int hook=0;hook<2;hook++) for(int fail=0;fail<2;fail++) {
  fixture_bind=true;fixture_hook=hook;fixture_fail=fail;host_calls=0;txns=0;
  assert(fakefs_unlink(&fixture_mount,"a")== (fail?-5:0));
  assert(fakefs_rmdir(&fixture_mount,"a")== (fail?-5:0));
  assert(fakefs_rename(&fixture_mount,"a","b")== (fail?-5:0));
  assert(fakefs_mkdir(&fixture_mount,"a",0700)== (fail?-5:0));
  assert(host_calls==4 && fixture_mount.fakefs.held==0);
  if(fail||hook)assert(txns==0);
 }
 fixture_bind=false;fixture_hook=false;fixture_fail=false;
 assert(fakefs_unlink(&fixture_mount,"a")==0);
 assert(fakefs_rmdir(&fixture_mount,"a")==0);
 assert(fakefs_rename(&fixture_mount,"a","b")==0);
 assert(fakefs_mkdir(&fixture_mount,"a",0700)==0);
 pids_lock=1;pid_slot.id=42;pid_slot.task=(void*)1;
 assert(allocation_failure()==NULL && pids_lock==0 && pid_slot.id==0 && pid_slot.task==NULL);
 struct mm mm={0};caller.mm=&mm;caller.mem=&mm;caller.mm_release_deferred=true;
 task_run_tlb_cleanup(NULL);assert(released_mm && !caller.mm_release_deferred);
 puts("PASS: external filesystem calls outside metadata lock (success/failure, hook/bind), local transaction preserved, OOM unlock/slot rollback, deferred mm unpublished before release");
 return 0;
}
'''
source=OUT/'kernel-locks.c';source.write_text(code,encoding='utf-8')
# Additional source invariants for the platform-specific stat structure and log hot paths.
stat=function(fake,'static int fakefs_stat(');a=stat.index('char host_stat_path[');stat=stat[a:]
assert stat.index('db_commit(fs)')<stat.index('stat(host_stat_path')
assert 'fake_stat->dev = dev_fake_from_real(host_stat.st_dev)' in fake
assert 'DEBUG_verbose &&' in fake and 'DEBUG_verbose &&' in read('Vendor/ZeNative/ish/fs/real.c')
if '--prepare-only' in sys.argv:print('PREPARE ONLY:',source);sys.exit(0)
compiler=['xcrun','clang'] if shutil.which('xcrun') else [os.environ.get('CC', 'cc')]
subprocess.run(compiler+['-std=c11','-Wall','-Wextra','-Werror',str(source),'-o',str(OUT/'kernel-locks')],check=True)
subprocess.run([str(OUT/'kernel-locks')],check=True)
