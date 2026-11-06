#!/usr/bin/env python3
"""Compile production native cancellation and bind-mount open flags with host fixtures."""
from pathlib import Path
import os, re, shutil, subprocess, sys, tempfile
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'ze-native-policy-tests';OUT.mkdir(exist_ok=True)
def read(p): return (ROOT/p).read_text(encoding='utf-8-sig')
def function(source, marker, last=False):
 start=source.rindex(marker) if last else source.index(marker)
 brace=source.index('{',start);depth=1;end=brace+1
 while depth:
  depth += (source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
native=read('Vendor/ZeNative/ish/kernel/native_offload.c')
ffmpeg=read('NativeOffloads/FFmpegOffload.m')
fake=read('Vendor/ZeNative/ish/fs/fake.c')
flags=fake[fake.index('        int real_flags = 0;'):fake.index('        int fd_no = open(host_abs')]
fs=read('Vendor/ZeNative/ish/kernel/fs.h')
flag_defs='\n'.join(line for line in fs.splitlines() if re.match(r'#define O_(?:RDONLY|WRONLY|RDWR|CREAT|EXCL|TRUNC|APPEND|NONBLOCK|NOFOLLOW)_\s',line))
header='''#define _DARWIN_C_SOURCE
#include <assert.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#define SIGKILL_ 9
#define SIGTERM_ 15
#define SIGINT_ 2
#define SIGQUIT_ 3
#define SIGHUP_ 1
#define printk(...) fprintf(stderr, __VA_ARGS__)
struct task { bool is_native_proxy; int native_pid; _Atomic(void *) native_offload_entry; atomic_int native_offload_cancelled; };
typedef bool (*native_abort_func)(struct task *, int);
struct offload_entry { char *guest_name; char *native_path; void *handler; native_abort_func abort_fn; };
static struct offload_entry offload_entries[3];
static int offload_count = 2;
static int killed_pid, killed_signal;
static int fixture_kill(int pid, int sig) { killed_pid=pid; killed_signal=sig; return 0; }
#define kill fixture_kill
'''
code=header+flag_defs+'\n'+function(native,'static int guest_to_host_signal(')+'\n'+function(native,'int native_offload_set_abort_handler(',True)+'\n'+function(native,'bool native_offload_forward_signal(',True)+'\n'+function(ffmpeg,'static bool ffmpeg_abort_requested(')+'\n'
code+='static int translated_flags(int flags) {\n'+flags+'return real_flags;\n}\n'
code+='''int main(void) {
 offload_entries[0]=(struct offload_entry){.guest_name="ffmpeg",.handler=(void*)1};
 offload_entries[1]=(struct offload_entry){.guest_name="host",.native_path="/usr/bin/true"};
 assert(native_offload_set_abort_handler("missing",ffmpeg_abort_requested)==-1);
 assert(native_offload_set_abort_handler("host",ffmpeg_abort_requested)==-1);
 assert(native_offload_set_abort_handler("ffmpeg",ffmpeg_abort_requested)==0);
 struct task active={0}, queued={0};
 atomic_store(&active.native_offload_entry,&offload_entries[0]);
 atomic_store(&queued.native_offload_entry,&offload_entries[0]);
 assert(!native_offload_forward_signal(&active,17));
 assert(atomic_load(&active.native_offload_cancelled)==0);
 assert(!native_offload_forward_signal(&queued,SIGTERM_));
 assert(atomic_load(&queued.native_offload_cancelled)==SIGTERM_);
 assert(atomic_load(&active.native_offload_cancelled)==0);
 for(int sig=1;sig<=31;sig++) {
  atomic_store(&active.native_offload_cancelled,0);
  assert(!native_offload_forward_signal(&active,sig));
  bool terminate=sig==1||sig==2||sig==3||sig==9||sig==15;
  assert((atomic_load(&active.native_offload_cancelled)!=0)==terminate);
 }
 atomic_store(&active.native_offload_entry,NULL);
 atomic_store(&active.native_offload_cancelled,0);
 assert(!native_offload_forward_signal(&active,SIGKILL_));
 assert(atomic_load(&active.native_offload_cancelled)==0);
 active.is_native_proxy=true;active.native_pid=42;
 assert(native_offload_forward_signal(&active,SIGTERM_));
 assert(killed_pid==42 && killed_signal==SIGTERM);
 char temp[]="/tmp/ze-nofollow-XXXXXX";char *dir=mkdtemp(temp);assert(dir);
 char file[256],link[256];snprintf(file,sizeof(file),"%s/file",dir);snprintf(link,sizeof(link),"%s/link",dir);
 int fd=open(file,O_CREAT|O_WRONLY,0600);assert(fd>=0);close(fd);assert(symlink(file,link)==0);
 errno=0;fd=open(link,translated_flags(O_RDONLY_|O_NOFOLLOW_));assert(fd<0 && errno==ELOOP);
 fd=open(link,translated_flags(O_RDONLY_));assert(fd>=0);close(fd);
 fd=open(file,translated_flags(O_RDONLY_|O_NOFOLLOW_));assert(fd>=0);close(fd);
 unlink(link);unlink(file);rmdir(dir);
 puts("PASS: actual native signal policy targets queued owner, ignores nonterminating signals, retains proxy forwarding; actual bind flags refuse symlinks with O_NOFOLLOW");
 return 0;
}
'''
source=OUT/'native-policy.c';source.write_text(code,encoding='utf-8')
assert 'atomic_store_explicit(&current->native_offload_entry, NULL' in native
assert 'pthread_mutex_trylock' in ffmpeg and 'ffmpeg_request_interrupt();' in ffmpeg
assert 'pthread_join(thr, NULL)' in ffmpeg and 'pthread_detach' not in ffmpeg
if '--prepare-only' in sys.argv:
 print('PREPARE ONLY:',source,'; compiler/runtime not executed');sys.exit(0)
compiler=['xcrun','clang'] if shutil.which('xcrun') else ['cc']
subprocess.run(compiler+['-std=c11','-Wall','-Wextra','-Werror',str(source),'-o',str(OUT/'native-policy')],check=True)
subprocess.run([str(OUT/'native-policy')],check=True)
