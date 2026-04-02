/*
 * Iris Language Runtime
 * Core types and utilities for generated C code.
 */
#ifndef IRIS_RUNTIME_H
#define IRIS_RUNTIME_H

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

/* ── view[String] — immutable view (pointer + length) ── */

typedef struct { const char* data; size_t len; } iris_view_String;

static inline iris_view_String iris_view_String_from(const char* s) {
  return (iris_view_String){s, strlen(s)};
}

/* ── str — static string reference (same layout as view[String]) ── */

typedef iris_view_String iris_str;
#define iris_str_from iris_view_String_from

/* ── String — owned heap buffer (pointer + length + capacity) ── */

typedef struct { char* data; size_t len; size_t cap; } iris_String;

static inline void iris_String_free(iris_String* s) {
  free(s->data); s->data = NULL; s->len = 0; s->cap = 0;
}

static inline iris_String iris_String_from(const char* s) {
  size_t len = strlen(s);
  char* data = (char*)malloc(len + 1);
  memcpy(data, s, len + 1);
  return (iris_String){data, len, len};
}

static inline iris_String iris_String_from_view(iris_view_String v) {
  char* data = (char*)malloc(v.len + 1);
  memcpy(data, v.data, v.len);
  data[v.len] = '\0';
  return (iris_String){data, v.len, v.len};
}

static inline iris_String iris_String_fmt(const char* fmt, ...) {
  va_list a1, a2;
  va_start(a1, fmt); va_copy(a2, a1);
  int len = vsnprintf(NULL, 0, fmt, a1); va_end(a1);
  char* data = (char*)malloc(len + 1);
  vsnprintf(data, len + 1, fmt, a2); va_end(a2);
  return (iris_String){data, (size_t)len, (size_t)len};
}

/* ── wyhash v4.3 by Wang Yi — public domain (Unlicense) ── */

static inline void _wymum(uint64_t *A, uint64_t *B) {
#if defined(__SIZEOF_INT128__)
  __uint128_t r = *A; r *= *B; *A = (uint64_t)r; *B = (uint64_t)(r >> 64);
#else
  uint64_t ha=*A>>32, hb=*B>>32, la=(uint32_t)*A, lb=(uint32_t)*B;
  uint64_t rh=ha*hb, rm0=ha*lb, rm1=hb*la, rl=la*lb;
  uint64_t t=rl+(rm0<<32), c=t<rl; uint64_t lo=t+(rm1<<32); c+=lo<t;
  *A=lo; *B=rh+(rm0>>32)+(rm1>>32)+c;
#endif
}

static inline uint64_t _wymix(uint64_t A, uint64_t B) { _wymum(&A,&B); return A^B; }
static inline uint64_t _wyr8(const uint8_t *p) { uint64_t v; memcpy(&v,p,8); return v; }
static inline uint64_t _wyr4(const uint8_t *p) { uint32_t v; memcpy(&v,p,4); return v; }

static inline uint64_t _wyr3(const uint8_t *p, size_t k) {
  return ((uint64_t)p[0]<<16)|((uint64_t)p[k>>1]<<8)|p[k-1];
}

static const uint64_t _wyp[4] = {
  0x2d358dccaa6c78a5ull, 0x8bb84b93962eacc9ull,
  0x4b33a62ed433d4a3ull, 0x4d5a2da51de1aa47ull
};

static inline uint64_t wyhash(const void *key, size_t len, uint64_t seed, const uint64_t *secret) {
  const uint8_t *p=(const uint8_t*)key; seed^=_wymix(seed^secret[0],secret[1]);
  uint64_t a,b;
  if(len<=16){
    if(len>=4){ a=(_wyr4(p)<<32)|_wyr4(p+((len>>3)<<2)); b=(_wyr4(p+len-4)<<32)|_wyr4(p+len-4-((len>>3)<<2)); }
    else if(len>0){ a=_wyr3(p,len); b=0; } else a=b=0;
  } else {
    size_t i=len;
    if(i>=48){ uint64_t see1=seed,see2=seed;
      do{ seed=_wymix(_wyr8(p)^secret[1],_wyr8(p+8)^seed);
        see1=_wymix(_wyr8(p+16)^secret[2],_wyr8(p+24)^see1);
        see2=_wymix(_wyr8(p+32)^secret[3],_wyr8(p+40)^see2);
        p+=48; i-=48; }while(i>=48); seed^=see1^see2; }
    while(i>16){ seed=_wymix(_wyr8(p)^secret[1],_wyr8(p+8)^seed); i-=16; p+=16; }
    a=_wyr8(p+i-16); b=_wyr8(p+i-8);
  }
  a^=secret[1]; b^=seed; _wymum(&a,&b);
  return _wymix(a^secret[0]^len, b^secret[1]);
}

static inline uint64_t wyhash64(uint64_t A, uint64_t B) {
  A^=0x2d358dccaa6c78a5ull; B^=0x8bb84b93962eacc9ull; _wymum(&A,&B);
  return _wymix(A^0x2d358dccaa6c78a5ull, B^0x8bb84b93962eacc9ull);
}

/* ── Hash/Eq helpers ── */

static inline uint64_t iris_hash_str(iris_str s) { return wyhash(s.data, s.len, 0, _wyp); }
static inline bool iris_eq_str(iris_str a, iris_str b) { return a.len==b.len && memcmp(a.data,b.data,a.len)==0; }
static inline uint64_t iris_hash_int(int64_t v) { return wyhash64((uint64_t)v, 0); }
static inline bool iris_eq_int(int64_t a, int64_t b) { return a==b; }
static inline uint64_t iris_hash_double(double v) { uint64_t u; memcpy(&u,&v,8); return wyhash64(u, 0); }
static inline bool iris_eq_double(double a, double b) { return a==b; }

#endif /* IRIS_RUNTIME_H */
