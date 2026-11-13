#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <time.h>
static void beat(const char *dir, int level) {
    char file[4096]; snprintf(file,sizeof(file),"%s/level%d.pid",dir,level);
    FILE *f=fopen(file,"w"); if(!f) _exit(3); fprintf(f,"%d",getpid()); fclose(f);
    snprintf(file,sizeof(file),"%s/level%d.beat",dir,level);
    for(int n=0;;n++) { f=fopen(file,"w"); if(f) { fprintf(f,"%d",n); fclose(f); } usleep(40000); }
}
int main(int argc,char **argv) {
    if(argc!=2) return 2;
    if(fork()==0) { if(fork()==0) beat(argv[1],2); beat(argv[1],1); }
    beat(argv[1],0);
}
