// sc-vision: tagfit's cell colours from NAPA's own family layout and code (so they always match what NAPA decoded).
// Header-only; include after napa_core.h. tag36h11 only (the FRC family).
#pragma once
#include <stdint.h>
#include <string.h>

#include "napa_core.h"

// (W + 2)^2 colours, 1 = white: quiet zone white, border black, payload from the code. cells must hold 18 x 18.
// Returns W (8 for tag36h11), or 0 if the family or id is unknown.
static inline int tagfit_napa_cells(int id, uint8_t *cells) {
  static napa_family_layout L;
  static int have = -1;
  if (have < 0) have = napa_family_info("tag36h11", &L) == 0 && L.width <= 16;
  if (!have) return 0;
  const int W = L.width, S = W + 2;
  memset(cells, 1, (size_t)S * S);
  for (int j = 0; j < W; j++)
    for (int i = 0; i < W; i++) cells[(j + 1) * S + i + 1] = 0;
  uint64_t code = 0;
  if (napa_tag36h11_code(id, &code)) return 0;
  for (int k = 0; k < L.nbits; k++) {
    const int x = L.x[k], y = L.y[k];
    if (x < -1 || y < -1 || x > W || y > W) continue;
    cells[(y + 1) * S + x + 1] = (code >> (L.nbits - 1 - k)) & 1;
  }
  return W;
}
