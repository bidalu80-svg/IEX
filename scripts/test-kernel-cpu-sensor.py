#!/usr/bin/env python3
"""Compile actual governor CPU sensor with injected Mach counter snapshots."""
from pathlib import Path
import os,shutil,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'iSH/ISHKernel.m').read_text(encoding='utf-8')
a=s.index('static uint64_t gov_process_cpu_ns(void) {');b=s.index('\n}',a)+2
out=Path(os.environ.get('RUNNER_TEMP',tempfile.gettempdir()))/'ze-cpu-sensor-tests';out.mkdir(exist_ok=True)
code=r'''#include <stdint.h>
#include <stdio.h>
#include <assert.h>
#define MACH_TASK_BASIC_INFO 1
#define TASK_THREAD_TIMES_INFO 2
#define MACH_TASK_BASIC_INFO_COUNT 4
#define TASK_THREAD_TIMES_INFO_COUNT 4
#define KERN_SUCCESS 0
typedef unsigned mach_msg_type_number_t;
typedef int *task_info_t;
struct time_value { int seconds; int microseconds; };
typedef struct {struct time_value user_time,system_time;} mach_task_basic_info_data_t;
typedef mach_task_basic_info_data_t task_thread_times_info_data_t;
static mach_task_basic_info_data_t dead_counter,live_counter;
static int fail_flavor;
static int mach_task_self(void){return 0;}
static int task_info(int task,int flavor,task_info_t data,mach_msg_type_number_t *count){
 (void)task;assert(*count==4);
 if(flavor==fail_flavor)return 1;
 *(mach_task_basic_info_data_t*)data=flavor==MACH_TASK_BASIC_INFO?dead_counter:live_counter;
 return KERN_SUCCESS;
}
'''+s[a:b]+r'''
int main(void){
 live_counter=(task_thread_times_info_data_t){{7,100000},{3,250000}};
 assert(gov_process_cpu_ns()==10350000000ULL);
 puts("PASS: still-running guest workers contribute CPU");
 dead_counter=live_counter;live_counter=(task_thread_times_info_data_t){0};
 assert(gov_process_cpu_ns()==10350000000ULL);
 puts("PASS: live-to-terminated handoff preserves total");
 dead_counter=(mach_task_basic_info_data_t){{2,1},{3,2}};
 live_counter=(task_thread_times_info_data_t){{5,3},{7,4}};
 assert(gov_process_cpu_ns()==17000010000ULL);
 puts("PASS: all user/system seconds and microseconds summed");
 dead_counter=(mach_task_basic_info_data_t){{100000,999999},{100000,999999}};
 live_counter=dead_counter;
 assert(gov_process_cpu_ns()==400003999996000ULL);
 puts("PASS: 64-bit conversion avoids long-session overflow");
 fail_flavor=MACH_TASK_BASIC_INFO;assert(gov_process_cpu_ns()==0);
 fail_flavor=TASK_THREAD_TIMES_INFO;assert(gov_process_cpu_ns()==0);
 puts("PASS: either failed sensor read returns skip sentinel");
 return 0;
}
'''
source=out/'cpu-sensor.c';source.write_text(code,encoding='utf-8')
compiler=['xcrun','clang'] if shutil.which('xcrun') else [os.environ.get('CC','cc')]
subprocess.run(compiler+['-std=c11','-Wall','-Wextra','-Werror',str(source),'-o',str(out/'cpu-sensor')],check=True)
subprocess.run([str(out/'cpu-sensor')],check=True)
