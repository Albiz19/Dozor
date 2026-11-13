#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <time.h>
#include <arpa/inet.h>
#include <sys/socket.h>
static int sink;
static struct sockaddr_in destination;
static void beat(const char *dir, int level) {
    char file[4096]; snprintf(file,sizeof(file),"%s/level%d.pid",dir,level);
    FILE *f=fopen(file,"w"); if(!f) _exit(3); fprintf(f,"%d",getpid()); fclose(f);
    snprintf(file,sizeof(file),"%s/level%d.beat",dir,level);
    for(int n=0;;n++) { f=fopen(file,"w"); if(f) { fprintf(f,"%d",n); fclose(f); }
        unsigned char tag=(unsigned char)level; sendto(sink,&tag,1,0,(struct sockaddr*)&destination,sizeof(destination)); usleep(40000); }
}
int main(int argc,char **argv) {
    if(argc!=3) return 2;
    sink=socket(AF_INET,SOCK_DGRAM,0);
    if(sink<0) return 3;
    destination.sin_family=AF_INET; destination.sin_len=sizeof(destination);
    destination.sin_port=htons((unsigned short)atoi(argv[2]));
    destination.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(fork()==0) { if(fork()==0) beat(argv[1],2); beat(argv[1],1); }
    beat(argv[1],0);
}
