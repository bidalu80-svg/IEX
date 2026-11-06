#!/usr/bin/env python3
"""Actual fakefs transaction/rename + inode lifecycle with deterministic DB fixtures."""
from pathlib import Path
import os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
def read(p):return (ROOT/p).read_text(encoding='utf-8')
def fn(s,key):
 a=s.index(key);b=s.index('{',a);d=1;i=b+1
 while d:d+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
fake=read('Vendor/ZeNative/ish/fs/fake.c');inode=read('Vendor/ZeNative/ish/fs/inode.c')
a=fake.index('    db_begin_read(fs);',fake.index('static struct fd *fakefs_open('));b=fake.index('    if (fd->fake_inode == 0) {\n        /* Auto-create',a)
open_section=fake[a:b]
header=r'''#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#define PATH_MAX 4096
#define O_CREAT_ 64
#define S_IFREG 0100000
#define _EROFS -30
#define _EXDEV -18
#define FAKEFS_CHANGE_OP_RENAME 1
struct list {int marker;};
struct fakefs_db {int held;};
struct mount;struct inode_data;
struct ops {void (*inode_orphaned)(struct mount *,ino_t);};
struct mount {struct fakefs_db fakefs;struct ops *fs;};
struct fd {ino_t fake_inode;};
struct ish_stat {int mode,uid,gid,rdev;};
struct task {int euid,egid;};static struct task task={1,2};static struct task *current=&task;
static struct mount fixture;
static int reads,writes,creates,cleanup_calls,change_calls;
static bool inject_creator,rename_fail,bind_mode,hook_mode;
static ino_t existing,src_inode,dst_inode,old_src,old_dst;
static int dst_paths;
static bool dst_metadata;
static int inodes_lock;
struct inode_data {int lock,refcount;struct mount *mount;ino_t number;struct list chain;};
static struct inode_data *opened_inode;
static void lock(int *l){assert(!*l);*l=1;}
static void unlock(int *l){assert(*l);*l=0;}
static void list_remove(struct list *l){(void)l;opened_inode=NULL;}
static void mount_release(struct mount *m){(void)m;assert(!inodes_lock);}
static struct inode_data *inode_get_data(struct mount *m,ino_t ino){(void)m;assert(inodes_lock);return opened_inode&&opened_inode->number==ino?opened_inode:NULL;}
static void orphaned(struct mount *m,ino_t ino){assert(inodes_lock&&!m->fakefs.held);assert(ino==22);cleanup_calls++;if(dst_paths==0)dst_metadata=false;}
static struct ops ops={orphaned};
static void db_begin_read(struct fakefs_db *fs){assert(!fs->held);fs->held=1;reads++;}
static void db_begin_write(struct fakefs_db *fs){assert(!fs->held);if(inject_creator){existing=77;inject_creator=false;}fs->held=2;writes++;old_src=src_inode;old_dst=dst_inode;}
static void db_commit(struct fakefs_db *fs){assert(fs->held);fs->held=0;}
static void db_rollback(struct fakefs_db *fs){assert(fs->held==2);src_inode=old_src;dst_inode=old_dst;fs->held=0;}
static ino_t path_get_inode(struct fakefs_db *fs,const char *path){assert(fs->held);if(!strcmp(path,"src"))return src_inode;if(!strcmp(path,"dst"))return dst_inode;return existing;}
static void path_create(struct fakefs_db *fs,const char *p,struct ish_stat *st){(void)p;(void)st;assert(fs->held==2&&existing==0);existing=99;creates++;}
static void path_rename(struct fakefs_db *fs,const char *src,const char *dst){(void)src;(void)dst;assert(fs->held==2);dst_inode=src_inode;src_inode=0;}
static bool is_under_readonly_bind_mount(const char *p){(void)p;return false;}
static bool bind_mount_translate_path_ex(const char *p,char *out,size_t n,bool *hook){(void)n;strcpy(out,p);*hook=hook_mode;return bind_mode;}
static int errno_map(void){return -5;}
static int host_rename(const char *a,const char *b){(void)a;(void)b;assert(!fixture.fakefs.held);return rename_fail?-1:0;}
#define rename host_rename
static int local_rename(struct mount *m,const char *a,const char *b){(void)a;(void)b;assert(m->fakefs.held==2);return rename_fail?-5:0;}
static struct {int (*host_rename)(struct mount*,const char*,const char*);}realfs={local_rename};
static void fakefs_record_change(const char *p,int op){(void)p;(void)op;change_calls++;}
'''
code=header+fn(inode,'void inode_check_orphaned(')+'\n'+fn(inode,'void inode_release(')+'\n'+fn(fake,'static int fakefs_rename(')+'\nstatic ino_t open_metadata(int flags) { struct fakefs_db *fs=&fixture.fakefs;struct fd value={0},*fd=&value;const char *path="open";int mode=0600;\n'+open_section+'return fd->fake_inode;\n}\n'
code+=r'''static void reset(void){reads=writes=creates=cleanup_calls=change_calls=0;existing=0;inject_creator=rename_fail=bind_mode=hook_mode=false;src_inode=11;dst_inode=22;dst_paths=0;dst_metadata=true;opened_inode=NULL;fixture.fs=&ops;assert(!fixture.fakefs.held&&!inodes_lock);}
int main(void){
 reset();existing=42;assert(open_metadata(0)==42&&reads==1&&writes==0);
 reset();existing=42;assert(open_metadata(O_CREAT_)==42&&reads==1&&writes==0);
 reset();assert(open_metadata(0)==0&&writes==0);
 reset();assert(open_metadata(O_CREAT_)==99&&reads==1&&writes==1&&creates==1);
 reset();inject_creator=true;assert(open_metadata(O_CREAT_)==77&&writes==1&&creates==0);
 puts("PASS: existing opens and O_CREAT existing need no writer; missing create rechecks under writer after concurrent creator");
 reset();assert(fakefs_rename(&fixture,"src","dst")==0&&cleanup_calls==1&&!dst_metadata);
 reset();opened_inode=calloc(1,sizeof(*opened_inode));assert(opened_inode);opened_inode->refcount=1;opened_inode->number=22;opened_inode->mount=&fixture;
 assert(fakefs_rename(&fixture,"src","dst")==0&&cleanup_calls==0&&dst_metadata);
 inode_release(opened_inode);assert(cleanup_calls==1&&!dst_metadata);
 puts("PASS: overwrite closed destination reclaims immediately; open destination survives until last close");
 reset();dst_paths=1;assert(fakefs_rename(&fixture,"src","dst")==0&&cleanup_calls==1&&dst_metadata);
 reset();dst_inode=src_inode;assert(fakefs_rename(&fixture,"src","dst")==0&&src_inode==11&&dst_inode==11&&cleanup_calls==0);
 puts("PASS: other hard link preserves destination metadata; same-inode rename preserves both source and destination names");
 reset();rename_fail=true;assert(fakefs_rename(&fixture,"src","dst")==-5&&src_inode==11&&dst_inode==22&&cleanup_calls==0&&dst_metadata);
 reset();rename_fail=true;bind_mode=true;assert(fakefs_rename(&fixture,"src","dst")==-5&&writes==0&&cleanup_calls==0);
 puts("PASS: failed local rename rolls back metadata without orphan cleanup; failed external rename starts no transaction");
 return 0;
}
'''
out=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'ze-fakefs-metadata-tests';out.mkdir(exist_ok=True)
source=out/'fakefs-metadata.c';source.write_text(code,encoding='utf-8')
compiler=['xcrun','clang'] if shutil.which('xcrun') else [os.environ.get('CC','cc')]
subprocess.run(compiler+['-std=c11','-Wall','-Wextra','-Werror',str(source),'-o',str(out/'fakefs-metadata')],check=True)
subprocess.run([str(out/'fakefs-metadata')],check=True)
