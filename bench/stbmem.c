/* Prints the peak heap memory stb_image uses to decode each JPEG given on the
   command line from memory (output image included, compressed input not). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static size_t cur, peak;
static void *track_malloc(size_t n) {
  size_t *p = malloc(n + 16); if (!p) return NULL;
  *p = n; cur += n; if (cur > peak) peak = cur; return (char *)p + 16;
}
static void track_free(void *q) {
  if (!q) return; size_t *p = (size_t *)((char *)q - 16); cur -= *p; free(p);
}
static void *track_realloc(void *q, size_t n) {
  if (!q) return track_malloc(n);
  size_t old = *(size_t *)((char *)q - 16);
  void *r = track_malloc(n); if (!r) return NULL;
  memcpy(r, q, old < n ? old : n); track_free(q); return r;
}
#define STBI_MALLOC track_malloc
#define STBI_FREE track_free
#define STBI_REALLOC track_realloc
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#include "stb_image.h"
int main(int argc, char **argv) {
  for (int f = 1; f < argc; f++) {
    FILE *fp = fopen(argv[f], "rb"); fseek(fp, 0, SEEK_END); long n = ftell(fp); rewind(fp);
    unsigned char *buf = malloc(n); fread(buf, 1, n, fp); fclose(fp);
    int w, h, c; cur = peak = 0;
    unsigned char *px = stbi_load_from_memory(buf, n, &w, &h, &c, 0);
    printf("%s peak %.1f MB (output %.1f MB)\n", strrchr(argv[f], '/') + 1, peak / 1e6, (double)w * h * c / 1e6);
    stbi_image_free(px); free(buf);
  }
}
