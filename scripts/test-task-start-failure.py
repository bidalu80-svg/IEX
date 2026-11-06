#!/usr/bin/env python3
"""Fault-inject pthread_create failures into actual task_start/discard functions."""
from pathlib import Path
import os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
s=(ROOT/'Vendor/ZeNative/ish/kernel/task.c').read_text(encoding='utf-8')
def function(marker):
 a=s.index(marker);b=s.index('{',a);depth=1;i=b+1
 while depth:depth+=(s[i]=='{')-(s[i]=='}');i+=1
 return s[a:i]
header=r'''#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#define _EAGAIN -11
#define _ENOMEM -12
struct list {struct list *prev,*next;};
static void list_init(struct list *l){l->prev=l->next=l;}
static void list_add(struct list *h,struct list *l){l->next=h->next;l->prev=h;h->next->prev=l;h->next=l;}
static void list_remove_safe(struct list *l){if(!l->next)return;l->prev->next=l->next;l->next->prev=l->prev;l->next=l->prev=NULL;}
static bool list_empty(struct list *l){return l->next==l;}
struct mm {int refs;};struct fdtable {int refs;};struct fs_info {int refs;};struct sighand {int refs;};
struct tgroup {struct list threads,pgroup;int lock,child_exit,stopped_cond;};
struct task {int thread,general_lock;struct mm *mm;void *mem;struct fdtable *files;struct fs_info *fs;struct sighand *sighand;struct tgroup *group;struct list group_links;};
static struct task *current;
static int pids_lock,session_releases,group_frees,task_destroys,cond_destroys,create_error;
static void lock(int *l){assert(!*l);*l=1;}
static void unlock(int *l){assert(*l);*l=0;}
static void cond_destroy(int *c){(void)c;cond_destroys++;}
static void task_leave_session(struct task *t){assert(pids_lock&&t->group->lock);session_releases++;}
static void task_destroy(struct task *t){assert(pids_lock&&t->group==NULL&&current!=t);task_destroys++;}
static void mm_release(struct mm *p){assert(!pids_lock);p->refs--;}
static void fdtable_release(struct fdtable *p){assert(!pids_lock);p->refs--;}
static void fs_info_release(struct fs_info *p){assert(!pids_lock);p->refs--;}
static void sighand_release(struct sighand *p){assert(pids_lock);p->refs--;}
static void fixture_free(void *p){assert(!pids_lock);group_frees++;free(p);}
#define free fixture_free
static int task_thread_attr;
static void *task_thread(void *p){return p;}
static int fixture_pthread_create(int *thread,int *attr,void *(*entry)(void *),void *arg){(void)thread;(void)attr;(void)entry;(void)arg;return create_error;}
#define pthread_create fixture_pthread_create
'''
code=header+function('void task_discard_unstarted(')+'\n'+function('int task_start(')+r'''
static struct tgroup *new_group(void){struct tgroup *g=calloc(1,sizeof(*g));assert(g);list_init(&g->threads);list_init(&g->pgroup);return g;}
int main(void){
 struct task t={0};
 create_error=EAGAIN;assert(task_start(&t)==_EAGAIN);
 create_error=ENOMEM;assert(task_start(&t)==_ENOMEM);
 create_error=EINVAL;assert(task_start(&t)==_ENOMEM);
 create_error=0;assert(task_start(&t)==0);assert(task_destroys==0);
 puts("PASS: positive pthread errno mapped; successful launch retains ownership");
 for(int shared=0;shared<2;shared++){
  struct mm mm={1+shared};struct fdtable files={1+shared};struct fs_info fs={1+shared};struct sighand sh={1+shared};
  struct tgroup *g=new_group();struct task parent={.group=g};
  if(shared)list_add(&g->threads,&parent.group_links);
  t=(struct task){.mm=&mm,.mem=&mm,.files=&files,.fs=&fs,.sighand=&sh,.group=g};
  list_add(&g->threads,&t.group_links);current=&t;
  int old_groups=group_frees,old_sessions=session_releases,old_cond=cond_destroys;
  create_error=EAGAIN;assert(task_start(&t)<0);task_discard_unstarted(&t);
  assert(!pids_lock&&!t.general_lock&&current==NULL);
  assert(t.mm==NULL&&t.mem==NULL&&t.files==NULL&&t.fs==NULL&&t.sighand==NULL&&t.group==NULL);
  assert(mm.refs==shared&&files.refs==shared&&fs.refs==shared&&sh.refs==shared);
  assert(group_frees-old_groups==!shared&&session_releases-old_sessions==!shared&&cond_destroys-old_cond==2*!shared);
  if(shared){assert(g->threads.next==&parent.group_links);list_remove_safe(&parent.group_links);free(g);}
 }
 puts("PASS: failed leader releases resources/group/session exactly once; failed shared thread preserves parent refs/group");
 task_discard_unstarted(NULL);
 assert(task_destroys==2);
 return 0;
}
'''
out=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'ze-task-start-tests';out.mkdir(exist_ok=True)
source=out/'task-start.c';source.write_text(code,encoding='utf-8')
compiler=['xcrun','clang'] if shutil.which('xcrun') else [os.environ.get('CC','cc')]
subprocess.run(compiler+['-std=c11','-Wall','-Wextra','-Werror',str(source),'-o',str(out/'task-start')],check=True)
subprocess.run([str(out/'task-start')],check=True)
for p in ['Vendor/ZeNative/ish/kernel/fork.c','iSH/ISHShellExecutor.m','iSH/ISHKernel.m']:
 text=(ROOT/p).read_text(encoding='utf-8')
 assert 'task_discard_unstarted(' in text and ('err = task_start(' in text or 'start_err = task_start(' in text),p
print('PASS: all three Ze launch callers handle failed start; full ObjC integration remains the app build')
