/* Decodes each JPEG given on the command line from memory with stb_image and
   prints the median decode time in milliseconds. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#include "stb_image.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
static int cmp(const void*a,const void*b){double x=*(double*)a,y=*(double*)b;return x<y?-1:x>y;}
int main(int argc,char**argv){
  for(int f=1;f<argc;f++){
    FILE*fp=fopen(argv[f],"rb");fseek(fp,0,SEEK_END);long n=ftell(fp);rewind(fp);
    unsigned char*buf=malloc(n);fread(buf,1,n,fp);fclose(fp);
    double t[64];int iters=0;double total=0;
    while(iters<64&&(total<1500||iters<5)){
      int w,h,c;double t0=now();unsigned char*px=stbi_load_from_memory(buf,n,&w,&h,&c,0);
      t[iters]=now()-t0;total+=t[iters++];if(!px){printf("FAIL %s\n",argv[f]);break;}stbi_image_free(px);}
    qsort(t,iters,sizeof(double),cmp);
    const char*b=strrchr(argv[f],'/');printf("%s %.2f\n",b?b+1:argv[f],t[iters/2]);free(buf);}
}
