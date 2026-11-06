#!/usr/bin/env python3
"""Real C cache/generic mutation regressions; host symlinks and cross-thread invalidation."""
from pathlib import Path
import os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
def read(p):return (ROOT/p).read_text(encoding='utf-8')
def fn(s,marker):
 a=s.index(marker);b=s.index('{',a);depth=1;i=b+1
 while depth:depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
p=read('Vendor/ZeNative/ish/fs/path.c');g=read('Vendor/ZeNative/ish/fs/generic.c')
cache=p[p.index('// === Path Normalize Cache'):p.index('static int __path_normalize(')]
header=r'''#define _DEFAULT_SOURCE
#include <assert.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <errno.h>
#define MAX_PATH 4096
#define AT_PWD ((struct fd *)-2)
#define N_SYMLINK_FOLLOW 1
#define N_SYMLINK_NOFOLLOW 2
#define N_PARENT_DIR_WRITE 4
#define _ENOENT -2
#define _ENAMETOOLONG -36
#define _EPERM -1
#define _EXDEV -18
#define _EBUSY -16
struct fd {int marker;};
struct fs_info {int lock;struct fd *root,*pwd;};
struct tgroup {uint64_t fs_context;};
struct task {unsigned pid,euid,egid;struct fs_info *fs;struct tgroup *group;};
static struct task *current;
static void lock(int *l){assert(!*l);*l=1;}
static void unlock(int *l){assert(*l);*l=0;}
static int generic_getpath(struct fd *at,char *out){(void)at;strcpy(out,"/");return 0;}
static bool path_is_normalized(const char *p){return p[0]=='/';}
static int walks;
static int __path_normalize(const char *at,const char *path,char *out,int flags,int levels){
 (void)at;(void)levels;walks++;
 if(strlen(path)>=MAX_PATH)return _ENAMETOOLONG;
 if(flags&N_SYMLINK_FOLLOW){ssize_t n=readlink(path,out,MAX_PATH-1);if(n>=0){out[n]=0;return 0;}}
 strcpy(out,path);return 0;
}
struct mount;
struct ops {int (*unlink)(struct mount*,const char*);int (*rename)(struct mount*,const char*,const char*);int (*symlink)(struct mount*,const char*,const char*);};
struct mount {struct ops *fs;};
static int host_unlink(struct mount *m,const char *p){(void)m;return unlink(p);}
static int host_rename(struct mount *m,const char *a,const char *b){(void)m;return rename(a,b);}
static int host_symlink(struct mount *m,const char *a,const char *b){(void)m;return symlink(a,b);}
static struct ops operations={host_unlink,host_rename,host_symlink};
static struct mount fixture_mount={&operations};
static struct mount *find_mount_and_trim_path(char *path){(void)path;return &fixture_mount;}
static void mount_release(struct mount *m){(void)m;}
static bool contains_mount_point(const char *p){(void)p;return false;}
'''
code=header+cache+fn(p,'int path_normalize(')+'\n'+'\n'.join(fn(g,'int generic_'+name+'(') for name in ['unlinkat','renameat','symlinkat'])+r'''
static void *invalidate_worker(void *arg){
 (void)arg;char out[MAX_PATH];
 // A newly-created host thread must not see another thread's populated table.
 assert(path_cache_get("/thread-private",1,out,path_cache_snapshot(),current->fs->root)==-1);
 path_cache_invalidate();return NULL;
}
int main(void){
 struct fd root={0},other_root={0};struct fs_info fs={.root=&root,.pwd=&root};struct tgroup group={1};struct task task={.pid=2,.fs=&fs,.group=&group};current=&task;
 char temp[]="/tmp/ze-path-cache-XXXXXX";assert(mkdtemp(temp));char link[512],replacement[512],out[MAX_PATH];snprintf(link,sizeof(link),"%s/link",temp);snprintf(replacement,sizeof(replacement),"%s/new",temp);
 assert(generic_symlinkat("/old",AT_PWD,link)==0);
 assert(path_normalize(AT_PWD,link,out,N_SYMLINK_FOLLOW)==0&&strcmp(out,"/old")==0);
 int before=walks;assert(path_normalize(AT_PWD,link,out,N_SYMLINK_FOLLOW)==0&&walks==before);
 assert(generic_symlinkat("/new",AT_PWD,replacement)==0);
 assert(generic_renameat(AT_PWD,replacement,AT_PWD,link)==0);
 assert(path_normalize(AT_PWD,link,out,N_SYMLINK_FOLLOW)==0&&strcmp(out,"/new")==0);
 assert(generic_unlinkat(AT_PWD,link)==0);
 assert(generic_symlinkat("/third",AT_PWD,link)==0);
 assert(path_normalize(AT_PWD,link,out,N_SYMLINK_FOLLOW)==0&&strcmp(out,"/third")==0);
 puts("PASS: real rename/unlink/symlink wrappers invalidate warm cached resolution immediately");
 uint64_t gen=path_cache_snapshot();path_cache_set("/thread-private",1,"/private",gen,&root);pthread_t worker;assert(pthread_create(&worker,NULL,invalidate_worker,NULL)==0);assert(pthread_join(worker,NULL)==0);
 assert(path_cache_get("/thread-private",1,out,path_cache_snapshot(),&root)==-1);
 path_cache_set("/raced",N_SYMLINK_FOLLOW,"/stale",gen,&root);
 assert(path_cache_get("/raced",N_SYMLINK_FOLLOW,out,path_cache_snapshot(),&root)==-1);
 puts("PASS: walk snapshot before another thread's mutation cannot publish a fresh stale entry");
 gen=path_cache_snapshot();path_cache_set("/scope",1,"/one",gen,&root);
 group.fs_context=2;assert(path_cache_get("/scope",1,out,gen,&root)==-1);group.fs_context=1;
 task.pid=3;assert(path_cache_get("/scope",1,out,gen,&root)==-1);task.pid=2;
 task.euid=1;assert(path_cache_get("/scope",1,out,gen,&root)==-1);task.euid=0;
 task.egid=1;assert(path_cache_get("/scope",1,out,gen,&root)==-1);task.egid=0;
 assert(path_cache_get("/scope",1,out,gen,&other_root)==-1);
 struct fs_info other_fs=fs;task.fs=&other_fs;assert(path_cache_get("/scope",1,out,gen,&root)==-1);task.fs=&fs;
 assert(path_cache_get("/scope",N_SYMLINK_NOFOLLOW,out,gen,&root)==-1);
 puts("PASS: TLS reuse cannot cross owner context, task, filesystem, chroot, credentials or follow mode");
 before=walks;assert(path_normalize(AT_PWD,link,out,N_SYMLINK_NOFOLLOW|N_PARENT_DIR_WRITE)==0);assert(path_normalize(AT_PWD,link,out,N_SYMLINK_NOFOLLOW|N_PARENT_DIR_WRITE)==0);assert(walks==before+2);
 char long_path[MAX_PATH+2];memset(long_path,'x',sizeof(long_path)-1);long_path[0]='/';long_path[sizeof(long_path)-1]=0;
 assert(path_normalize(AT_PWD,long_path,out,1)==_ENAMETOOLONG);
 puts("PASS: mutation permission walks bypass cache; oversized key reaches ENAMETOOLONG");
 uint64_t prior=path_cache_snapshot();assert(generic_unlinkat(AT_PWD,"/definitely-missing-ze-path")<0);assert(path_cache_snapshot()==prior);
 unlink(link);rmdir(temp);
 return 0;
}
'''
out=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'ze-path-cache-tests';out.mkdir(exist_ok=True)
source=out/'path-cache.c';source.write_text(code,encoding='utf-8')
compiler=['xcrun','clang'] if shutil.which('xcrun') else [os.environ.get('CC','cc')]
subprocess.run(compiler+['-std=c11','-Wall','-Wextra','-Werror','-pthread',str(source),'-o',str(out/'path-cache')],check=True)
subprocess.run([str(out/'path-cache')],check=True)
for name in ['linkat','unlinkat','renameat','symlinkat','mknodat','mkdirat','rmdirat','setattrat']:
 assert 'if (err >= 0) path_cache_invalidate();' in fn(g,'int generic_'+name+'('),name
assert 'if (flags & O_CREAT_) path_cache_invalidate();' in g
for name in ['do_mount','mount_remove']:
 assert 'path_cache_invalidate();' in fn(read('Vendor/ZeNative/ish/fs/mount.c'),'int '+name+'(')
for name in ['fakefs_bind_mount','fakefs_bind_unmount']:
 body=fn(read('Vendor/ZeNative/ish/fs/fake.c'),'int '+name+'(')
 assert body.count('return 0;')==body.count('path_cache_invalidate();'),name
assert 'path_cache_invalidate();' in fn(read('Vendor/ZeNative/ish/kernel/fs.c'),'static int generic_fsetattr(')
assert 'path_cache_invalidate();' in fn(read('Vendor/ZeNative/ish/fs/sock.c'),'static int unix_socket_get(')
print('PASS: mutation integration covers link/unlink/rename/symlink/mknod/mkdir/rmdir/create, setattr/fsetattr, mount/remove and every successful bind route')
