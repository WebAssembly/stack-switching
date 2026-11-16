// nqueens via concurrency
// TODO: convert from Go!

#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

#include <fiber.h>

type queenboard = [8]int

// Each time we print the board we get this global lock, to prevent interleaving of the output from multiple threads.
var printlock sync.Mutex
// WaitGroup is a standard abstraction for waiting on a collection of threads to finish.
var waitGroup sync.WaitGroup

func printBoard(board queenboard) {
  // Take the global printing lock to prevent interleaving of output.
  printlock.Lock()
  defer printlock.Unlock()  // Auto-drop the lock at end.

  fmt.Printf("----------------\n")
  for i := 0; i < 8; i++ {
    for j := 0; j < 8; j++ {
      if board[i] == j {
        print("Q ")
      } else {
        print(". ")
      }
    }
    fmt.Printf("\n")
  }
  fmt.Printf("\n")
}

func isSafe(row, col int, board queenboard) bool {
  for i := 0; i < row; i++ {
    // Check for collision of a queen at (row,col) with a queen at (i, board[i]).
    // Collisions can be for "same col" or for either of two diagonals.
    // Collisions via "same row" are impossible based on the representation of the board.
    if board[i] == col || col-board[i] == (row-i) || board[i]-col == (row-i) {
      return false
    }
  }
  return true
}

func findQueens(row int, board queenboard) {
  defer waitGroup.Done()  // No matter how we exit, ensure we signal Done to the waitGroup.

  if row == 8 {
    printBoard(board)
    return
  }

  for col := 0; col < 8; col++ {
    if isSafe(row, col, board) {
      newBoard := queenboard{}
      copy(newBoard[:], board[:])
      newBoard[row] = col

      waitGroup.Add(1)
      go findQueens(row + 1, newBoard)
    }
  }
}

func main() {
  waitGroup.Add(1)
  findQueens(0, queenboard{-1, -1, -1, -1, -1, -1, -1, -1})

  // Wait for all threads to finish before exiting.
  waitGroup.Wait()
}
