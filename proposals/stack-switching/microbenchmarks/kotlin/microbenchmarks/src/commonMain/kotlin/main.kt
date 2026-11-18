import kotlinx.coroutines.*
import kotlin.random.*
import kotlin.math.*
import kotlin.time.measureTime
import OutputMode

val VERBOSE = false;

enum class OutputMode {
    HUMAN, CSV // TODO: add JSON output?
}

val outputMode = OutputMode.CSV

fun main(args: Array<String>) {
    println("Hello from Kotlin/Wasm")

    MainScope().launch {
        var itersumSize = 10_000_000
        println("\n# --- Itersum $itersumSize ---")
        testItersum(itersumSize)
    }

    MainScope().launch {
        var treesumSize = 25
        println("\n# --- Treesum $treesumSize ---")
        testTreesum(treesumSize)
    }

    MainScope().launch {
        println("\n# --- Pi ---")

        simpleBenchmarkWell("pi", ::pi)
    }
}
suspend fun simpleBenchmarkWell(name : String, experiment : suspend () -> Unit) {
    benchmarkWell(name, {}, {_ -> experiment()})
}

suspend fun <T>benchmarkWell(
    name : String,
    setup : suspend () -> T,
    experiment : suspend (T) -> Unit)
{
    val durations : MutableList<Long> = mutableListOf();

    for (i in 0..numWarmups+numTrials-1) {
        val v = setup()
        var sum = 0
        val duration = measureTime {
            experiment(v)
        }
        if (i >= numWarmups)  // Discard the warmup measurement
            durations.add(duration.inWholeMilliseconds);
    }

    val mean : Long = durations.sum() / durations.size;
    val stddev = sqrt(durations.map{ sqr((it - mean).toDouble()) }.sum());

    durations.sort()
    var median = durations.get(5)
    val min = durations.get(0)
    val max = durations.get(numTrials-1)
    val q1 = durations.get((numTrials*0.25).toInt())
    val q3 = durations.get((numTrials*0.75).toInt())

    if (outputMode == OutputMode.HUMAN) {
        println("\nRecorded ${durations.size} samples\n")
        println("Mean Duration: ${mean}ms")
        println("StdDev Duration: ${stddev.toLong()}ms")
        println("")
        println("Median Duration: ${median}ms")
        println("Min-Max: ${min}ms ; ${max}ms (range ${max-min}ms)")
        println("quartiles q1, q3: ${q1}ms ; ${q3}ms. IQR: ${q3 - q1}ms")
    }

    if (outputMode == OutputMode.CSV) {
        println("benchmark,mean,stddev,median,min,max,q1,q3,n")
        println("$name,$mean,$stddev,$median,$min,$max,$q1,$q3,${durations.size}")
    }
}

fun sqr(x : Double) : Double {
    return x * x;
}

val numWarmups = 3
val numTrials = 11

suspend fun testItersum(size: Int) {

    val range = sequence {
        var i = 0
        while (true) {
            yield(i++)
        }
    }

    benchmarkWell("itersum",
    {
        val range = sequence {
            var i = 0
            while (true) {
                yield(i++)
            }
        }
        range
    },
    { range: Sequence<Int> ->
        val sum = range.take(size).sum()
        // println("Sum: $sum")
    })
}

class Node(val height: Int, val left: Node?, val right: Node?) {
}

fun buildTree(height: Int) : Node {
    if (height == 0) {
        return Node(1, null, null)
    }

    val child = buildTree(height - 1)

    return Node(height, child, child)
}

suspend fun SequenceScope<Int>.searchTree(t: Node) { //}: Sequence<Int> = sequence {
    if (t.left == null || t.right == null) {
        yield(t.height)
    } else {
        searchTree(t.left)
        searchTree(t.right)
    }
}

suspend fun testTreesum(height: Int) {
    benchmarkWell("treesum",
    {
        val tree = buildTree(height)
        val range = sequence {searchTree(tree)};
        range
    }, { range ->
        val sum = range.sum()
        // println("Sum: $sum")
    })
}

suspend fun pi() {
    val duration = measureTime {
        val threads = mutableListOf<Deferred<Unit>>()
        withContext(Dispatchers.Default) {
            for (i in 0 .. numTasks) {
                threads.add(MainScope().async {
                    val pi = monteCarloPi()
//                    println("Estimated Pi: $pi")
                })
            }
            for (t in threads) {
                t.await()
            }
        }
    }
    // println("Duration for pi (one trial): $duration")
}

val batches = 50
val batchSize = 20_000
val numTasks = 1000

suspend fun monteCarloPi() : Double {
    var inside = 0
    var total = 0
    for (i in 0 until batches) {
        for (j in 0 until batchSize) {
            val x = Random.nextFloat()
            val y = Random.nextFloat()
            if (x * x + y * y <= 1.0) {
                inside++
            }
            total++
        }
        delay(0)  // Needed to yield to other coroutines.
    }
    return 4.0 * inside / total
}


// Run with/after others:
// Median Duration: 8178ms
// Min-Max: 7924ms ; 8230ms (range 306ms)
// quartiles q1, q3: 8142ms ; 8193ms. IQR: 51ms

// Run alone:
// Median Duration: 8347ms
// Min-Max: 7145ms ; 8403ms (range 1258ms)
// quartiles q1, q3: 8212ms ; 8379ms. IQR: 167ms