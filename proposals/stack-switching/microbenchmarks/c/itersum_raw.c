// Iterative sum; an iterative variation of `treesum.c`

// compile with clang -O1. Low optimization is needed to prevent optimizing away the loop!

#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>


// Calculates the sum of the numbers 0..max.
int32_t run(int32_t max) {
  int32_t result = 0, i = 0;

  while (i++ < max) {
    result += (int32_t)(intptr_t)i;
  }

  return result;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "Wrong number of arguments. Expected: 1");
    return -1;
  }

  int i = atoi(argv[1]);

  int32_t result = run(i);

  printf("%d\n", result);

  return 0;
}
