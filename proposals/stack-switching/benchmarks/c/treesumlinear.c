// Tree traversal; a recursive variation of `itersum.c`
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
      struct node *left;
      struct node *right;
    };
  };
} node_t;

// Build a full, "bushy" binary tree of the given depth. By bushy, we mean that
// all branches have the same length. In fact, the tree *shares* its right and
// left branches at every point.
node_t* build_full_tree(int32_t depth, int32_t val) {
  node_t *node = (node_t*)malloc(sizeof(node_t));
  if (depth == 0) {
    node->tag = LEAF;
    node->val = val;
  } else {
    node->tag = FORK;
    // node_t *subtree = build_full_tree(depth - 1, val + 1);
    node_t *subtree = build_full_tree(depth - 1, 1);
    node->left = subtree;
    node->right = subtree;
  }
  return node;
}

// Build a tree of the given size. The tree is built by composing it of subtrees
// at power-of-two sizes, and using build_full_tree to build those. We look at
// the bit representation of the size to determine which subtrees to include.
node_t* build_tree(int32_t size, int32_t val) {
  node_t *trees[32];  // up to 32 possible subtrees
  int i = 0;  // number of trees built so far
  int32_t depth = 0;  // depth of the next tree to build.
  while (size > 0) {
    if (size & 0x1) {
      node_t *leaf = (node_t*)malloc(sizeof(node_t));
      leaf->tag = LEAF;
      leaf->val = val;
      size -= 1;
      trees[i++] = build_full_tree(depth, val);
    }
    depth++;
    size /= 2;
  }

  // Combine all built trees into a single tree, in a left-linear fashion. I had
  // thought to make this upper tree balanced, but in fact since the shortest
  // component trees were generated on the left, the unbalanced nature of the
  // supertree kind of rebalances the whole. Nice.
  if (i == 0) {
    return NULL;
  }
  if (i == 1) {
    return trees[0];
  }
  node_t *root = (node_t*)malloc(sizeof(node_t));
  root->tag = FORK;
  root->left = trees[0];
  root->right = trees[1];
  for (int j = 2; j < i; j++) {
    node_t *new_root = (node_t*)malloc(sizeof(node_t));
    new_root->tag = FORK;
    new_root->left = root;
    new_root->right = trees[j];
    root = new_root;
  }
  return root;
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

void walk_tree(node_t *node) {
  if (node->tag == LEAF) {
    fiber_yield((void*)(intptr_t)node->val);
  } else {
    walk_tree(node->left);
    walk_tree(node->right);
  }
}

void* tree_walker(void *node) {
  walk_tree((node_t*)node);
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

  int size = atoi(argv[1]);
  if (size > 0x7FFFFFFF) {
    fprintf(stderr, "Too large a tree requested.");
    return 1;
  }
  node_t *tree = build_tree((int32_t)size, 0);

  int32_t result = run(tree);

  free_tree(tree);

  printf("%d\n", result);

  fiber_finalize();
  return 0;
}


// 20,000,000 decimal is
// 00000001001100010010110100000000 binary
// ...|...|...|...|...|...|...|...|
// eight component trees
// depths 8, 10, 11, 13, 16, 20, 21, 24
//        8,  7,  6,  5,  4,  3,  2,  1
//       16, 17, 17, 18, 20, 23, 23, 25