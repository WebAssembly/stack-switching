// Tree traversal; a recursive variation of `itersum.c`
// Now using `switch`!
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdio.h>
#include <fiber_switch.h>

#include <string.h>

static bool walk_done = false;

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

node_t* build_tree(int32_t depth, int32_t val) {
  node_t *node = (node_t*)malloc(sizeof(node_t));
  if (depth == 0) {
    node->tag = LEAF;
    node->val = val;
  } else {
    node->tag = FORK;
    node->height = depth;
    node_t *subtree = build_tree(depth - 1, val + 1);
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

int32_t walk_tree(node_t const *const node, fiber_t switch_back) {
  assert(switch_back != NULL);
  if (node->tag == LEAF) {
    (void)fiber_switch(switch_back, (void*)(intptr_t)node->val, &switch_back);
    return node->val;
  } else {
    int sum = walk_tree(node->left, switch_back);
    sum += walk_tree(node->right, switch_back);
    return sum;
  }
}

void* tree_walker(void const *const arg, fiber_t caller) {
  assert(caller != NULL);
  node_t *node = (node_t*)arg;
  int const target_iterations = 1 << 25;
  int const tree_leaves = (1 << node->height);
  int const reps = target_iterations / tree_leaves;

  // Run "reps" times to ensure that we always do 32M iterations, regardless of the tree height.
  for (int i = 0; i < reps; i++) {
    walk_done = false;
    int result = walk_tree((node_t*)node, caller);
    assert(result == node->height * tree_leaves && "answer verification failed.");
    walk_done = true;
  }

  fiber_switch_return(caller, NULL);
  return NULL;
}

void* run(node_t const *const tree, fiber_t caller) {
  assert(caller != NULL);
  int32_t sum = 0;

  fiber_t walker = fiber_alloc((fiber_entry_point_t)tree_walker);
  void* val = fiber_switch(walker, (void*)tree, &walker);

  while (!walk_done) {
    sum += (int32_t)(intptr_t)val;
    val = fiber_switch(walker, NULL, &walker);
  }

  fiber_free(walker);
  fiber_switch_return(caller, (void*)(intptr_t)sum);
  return NULL;
}

void *prog(int argc, char **argv) {

  if (argc != 2) {
    fprintf(stderr, "Wrong number of arguments. Expected: 1");
    return 0;
  }

  int32_t const i = (int32_t)atoi(argv[1]);
  node_t *tree = build_tree(i, 0);

  fiber_t runner = fiber_alloc((fiber_entry_point_t)run);
  int32_t const result = (int32_t)(intptr_t)fiber_switch(runner, (void*)(intptr_t)tree, &runner);

  fiber_free(runner);
  free_tree(tree);
  return (void*)(intptr_t)result;
}

int main(int argc, char** argv) {

  int32_t const result = (int32_t)(intptr_t)fiber_main(prog, argc, argv);
  printf("%d\n", result);

  return 0;
}
