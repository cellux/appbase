#include <stdint.h>
#include <string.h>
#include <stdlib.h>

#include "buffer.h"

#define nearest_multiple_of(a, b) \
  (((b) + ((a) - 1)) & ~((a) - 1))

void zz_buffer_init(zz_buffer_t *self,
                    uint8_t *data,
                    uint32_t size,
                    uint32_t capacity,
                    int dynamic) {
  self->data = data;
  self->size = size;
  self->capacity = capacity;
  self->dynamic = dynamic;
}

zz_buffer_t * zz_buffer_new() {
  return zz_buffer_new_with_capacity(ZZ_BUFFER_DEFAULT_CAPACITY);
}

zz_buffer_t * zz_buffer_new_with_capacity(uint32_t capacity) {
  zz_buffer_t *self = malloc(sizeof(zz_buffer_t));
  if (!self) {
    return NULL;
  }
  uint8_t *data = calloc(capacity, 1);
  if (!data) {
    free(self);
    return NULL;
  }
  uint32_t size = 0;
  int dynamic = 1;
  zz_buffer_init(self, data, size, capacity, dynamic);
  return self;
}

zz_buffer_t * zz_buffer_new_with_data(void *data, uint32_t size) {
  zz_buffer_t *self = zz_buffer_new_with_capacity(size);
  if (self) {
    memcpy(self->data, data, size);
    self->size = size;
  }
  return self;
}

uint32_t zz_buffer_resize(zz_buffer_t *self, uint32_t n) {
  if (!self->dynamic) return 0;
  n = nearest_multiple_of(1024, n);
  self->data = realloc(self->data, n);
  if (!self->data) return 0;
  self->capacity = n;
  if (self->capacity < self->size) {
    self->size = self->capacity;
  }
  return self->capacity;
}

uint32_t zz_buffer_append(zz_buffer_t *self, const void *data, uint32_t size) {
  uint32_t new_size = self->size + size;
  if (new_size > self->capacity) {
    if (!zz_buffer_resize(self, new_size)) {
      return 0;
    }
  }
  memcpy(self->data + self->size, data, size);
  self->size = new_size;
  return size;
}

int zz_buffer_equals(zz_buffer_t *self, zz_buffer_t *other) {
  return (self->size == other->size) &&
    (0 == memcmp(self->data, other->data, self->size));
}

void zz_buffer_fill(zz_buffer_t *self, uint8_t c) {
  memset(self->data, c, self->size);
}

void zz_buffer_clear(zz_buffer_t *self) {
  zz_buffer_fill(self, 0);
}

void zz_buffer_reset(zz_buffer_t *self) {
  self->size = 0;
}

void zz_buffer_free(zz_buffer_t *self) {
  if (self->data) {
    free(self->data);
    self->data = NULL;
  }
  free(self);
}