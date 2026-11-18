import kotlinx.coroutines.*
import kotlin.math.*
import kotlin.time.measureTime

val VERBOSE = false;

val batches = 50
val batchSize = 100_000
val numTasks = 1000

fun main() {
    println("Hello from Kotlin/Wasm")

    val threads = listOf()
    for (i in 0 .. numTasks) {
        threads.add(MainScope().launch {
            val pi = monteCarloPi()
            println("Estimated Pi: $pi")
        })
    }
}

fun monteCarloPi() : Generator<Double> {
    var inside = 0
    var total = 0
    for (i in 0 until batches) {
        for (j in 0 until bachSize) {
            val x = Math.random()
            val y = Math.random()
            if (x * x + y * y <= 1.0) {
                inside++
            }
            total++
        }
        yield()
    }
    return 4.0 * inside / total
}
