// Tree traversal; a recursive variation of `itersum.c`
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <fiber.h>

typedef struct node {
  enum { LEAF, FORK } tag;
  union {
    // Leaf.
    int32_t val;
    // Fork
    struct {
      int height;
      struct node *left;
      struct node *right;
    };
  };
} node_t;

node_t* build_tree(int32_t height, int32_t val) {
  node_t *node = (node_t*)malloc(sizeof(node_t));
  if (height == 0) {
    node->tag = LEAF;
    node->val = val;
  } else {
    node->tag = FORK;
    node->height = height;
    node_t *subtree = build_tree(height - 1, val + 1);
    node->left = subtree;
    node->right = subtree;
  }
  return node;
}

void free_tree(node_t *node) {
  enum { LEAF, FORK } tag = node->tag;
  if (tag == FORK) {
    if (node->left == node->right) {
      free_tree(node->left);
    } else {
      free_tree(node->left);
      free_tree(node->right);
    }
  }
  free(node);
}

int32_t walk_tree(node_t *node) {
  if (node->tag == LEAF) {
    fiber_yield((void*)(intptr_t)node->val);
    return node->val;
  } else {
    int sum = walk_tree(node->left);
    sum += walk_tree(node->right);
    if (sum % 2 == 0) {
      return sum;
    } else {
      return sum + node->height;
    }
  }
}

void* tree_walker(void *arg) {
  node_t *node = (node_t*)arg;
  int const target_iterations = 1 << 25;
  int const tree_leaves = (1 << node->height);
  int const reps = target_iterations / tree_leaves;
  // Run "reps" times to ensure that we always do 32M iterations, regardless of the tree height.
  for (int i = 0; i < reps; i++) {
    int result = walk_tree(node);
    assert (result == node->height * tree_leaves && "answer verification failed.");
  }
  return NULL;
}

int32_t run(node_t* tree) {
  fiber_result_t status;
  int32_t sum = 0;
  fiber_t walker = fiber_alloc(tree_walker);

  void* val = fiber_resume(walker, (void*)tree, &status);

  while (status == FIBER_YIELD) {
    sum += (int32_t)(intptr_t)val;
    val = fiber_resume(walker, NULL, &status);
  }

  fiber_free(walker);
  return sum;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "Wrong number of arguments. Expected: 1");
    return -1;
  }
  fiber_init();

  int height = atoi(argv[1]);
  assert (height <= 25 && "height must be <= 25 to ensure the expected number of iterations is hit");
  node_t *tree = build_tree((int32_t)height, 0);

  int32_t result = run(tree);

  free_tree(tree);

  printf("%d\n", result);

  fiber_finalize();
  return 0;
}
