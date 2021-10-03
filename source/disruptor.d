/**
An implementation of the [fowler].

A disruptor is glorified ring buffer that allows multiple consumers to
read its contents. This implementation is only threadsafe for a single
producer. It differs from a normal single producer / multi consumer queue
in the following points:

$(LIST
  * Slots are not distributed between consumers. Every consumer can consume each slot.
  * Slow consumer can catch up by consuming multiple slots at once.
  * Consumers can coordinate between each other by forming a dependency graph. If
consumer A declares to depend on consumer B, it will only be able to read
a slot after B has finished consuming it.
)

To interact with the disruptor a producer just calls [Disruptor.produce],
while consumers need to aquire a [ConsumerToken] first. The token tracks
the current position of the consumer in the ringbuffer and on which other
consumers it depends.

Link_References:
    fowler = [https://martinfowler.com/articles/lmax.html | Disruptor Pattern]
*/

module disruptor.disruptor;

import std.math : nextPow2;
import std.algorithm : map;
import std.range;

/**
ConsumerToken are used by consumers to interact with the [Disruptor]


Consumer must receive exactly one token via a call to
`createConsumerToken` and provide it on every call
to Disruptor.consume.

Consumer tokens are also used to track dependencies between
different consumers, e.g. if A may only consume slots that
have alreay been consumed by B.

---
auto tokenA = disruptor.createConsumerToken();
auto tokenB = disruptor.createConsumerToken();
tokenA.waitFor(B);
---
*/
struct ConsumerToken
{
    ubyte[7] dependencies = [ ubyte.max, ubyte.max, ubyte.max,
        ubyte.max, ubyte.max, ubyte.max, ubyte.max ];
    ubyte ownSlot;

    this(ubyte slot) { ownSlot = slot; }

    void waitFor(const ConsumerToken other)
    {
        import std.algorithm.searching : find;
        dependencies[].find(ubyte.max).front = other.ownSlot;
    }
}

/**
A single-producer, multiple consumer disruptor implementation

$(LIST
        * T = The type of the slots
        * Size = size of the ring buffer in slots. Rounded up to the next
           power of 2.
        * Consumers = number of [ConsumerToken] the disruptor can issue
)
*/
struct Disruptor(T, ulong Size=nextPow2(10_000), ulong Consumers=63)
{
    import core.atomic : atomicLoad, atomicStore, atomicOp, MemoryOrder, atomicFence;

    @disable this(this);
    @disable this(ref return scope inout Disruptor another);
private:
    // counters[0] is the producer's counter,
    ulong[Consumers+1] counters;

    // the number of registered consumers
    shared ubyte consumerCount = 0;

    // where the data is actually stored
    T[Size] ringBuffer = void;

    /*
    Returns the last slot the producer has written to
    or 0 if nothing has been produced yet.

    The first slot the producer writes to is 1.
    */
    ulong producerCount() const shared
    {
        return counters[0].atomicLoad!(MemoryOrder.acq);
    }

    /*
    Returns the counter of the slowest consumer
    */
    ulong minConsumerCount() const shared
    {
        import std.algorithm : map, minElement;
        if (consumerCount == 0)
            return 0;
        return counters[1 .. consumerCount+1]
            .map!((ref x) => x.atomicLoad!(MemoryOrder.acq))
            .minElement;
    }
public:
    void initialize()
    {
        foreach(i; 0 .. Size)
        {
            import core.lifetime : emplace;
            emplace(&ringBuffer[i], 0);
        }
    }

    /**
    Iff there is more room in the Disruptor, calls [#param-del|del]
    with a reference to the free slot. The second argument [#param-index|index]
    is the index of the slot.

    Returns:
        true, if the delegate was called
        false, otherwise (Disruptor is full)
    */
    bool produce(scope void delegate(ref T slot, ulong index) del) shared
    {
        ulong nextSlot = counters[0] + 1;

        ulong minConsumer = minConsumerCount();
        bool full = minConsumer + Size < nextSlot;
        if (!full)
        {
            T[] frame = cast(T[])(ringBuffer);
            static if (__traits(hasMember, T, "reuse"))
                frame[nextSlot % Size].reuse();
            del(frame[nextSlot % Size], nextSlot);
            counters[0].atomicStore!(MemoryOrder.rel)(nextSlot);
        }
        return !full;
    }

    /**
    Consume from the Disruptor. Calls del with the slice of produced but not
    consumed elements. The argument firstIndex is the index of the
    first element in slice.

    Only calls del if there is something to consume (slice is never empty).

    Returns: true, if del was called, otherwise false.
    */
    bool consume(ConsumerToken token, scope void delegate(T[] slice, ulong firstIndex) del) shared
    {
        import std.range : only, chain;
        import std.algorithm : map, filter, minElement;

        ulong max = only(producerCount())
            .chain(token.dependencies[].filter!(x => x != ubyte.max)
                .map!(x => counters[x]))
            .minElement;
        import std.stdio;
        ulong myCounter = counters[token.ownSlot].atomicLoad!(MemoryOrder.acq);
        assert (max >= myCounter);
        ulong nextToRead = myCounter + 1;
        if (nextToRead <= max)
        {
            const auto start = nextToRead % Size;
            auto end = (max + 1) % Size;
            T[] frame = cast(T[]) {
                if (start > end)
                    return ringBuffer[start .. $];
                return ringBuffer[start .. end];
            }();

            del(frame, nextToRead);
            counters[token.ownSlot].atomicStore!(MemoryOrder.rel)(max);
            return true;
        }
        return false;
    }

    /// Generate a new consumer token.
    ConsumerToken createConsumerToken() shared
    {
        ubyte token = atomicOp!("+=")(consumerCount, 1);
        return ConsumerToken(token);
    }
}

///
unittest {
    import std.functional : toDelegate;
    alias D = Disruptor!int;

    int testInt = ubyte.max;
    auto doNothing = (int[] values, ulong idx) {
        if (!values.empty)
            testInt = values[0];
    };

    shared D d;
    ConsumerToken consumer1 = d.createConsumerToken();
    ConsumerToken consumer2 = d.createConsumerToken();

    assert (!d.consume(consumer1, doNothing));
    assert (!d.consume(consumer2, doNothing));

    d.produce((ref int v, ulong _) {
        v = 1;
    }.toDelegate());

    assert (d.consume(consumer1, doNothing));
    assert (testInt == 1);
    assert (!d.consume(consumer1, doNothing));
    testInt = 2;
    assert (d.consume(consumer2, doNothing));
    assert (testInt == 1);
    assert (!d.consume(consumer2, doNothing));
}

///
unittest
{
    import std.functional : toDelegate;
    alias D = Disruptor!int;

    int testInt = ubyte.max;
    auto doNothing = (int[] values, ulong idx) {
        if (!values.empty)
            testInt = values[0];
    };

    shared D d;
    ConsumerToken consumer1 = d.createConsumerToken();
    ConsumerToken consumer2 = d.createConsumerToken();
    consumer2.waitFor(consumer1);

    assert (!d.consume(consumer1, doNothing));
    assert (!d.consume(consumer2, doNothing));

    d.produce((ref int v, ulong _) {
        v = 1;
    }.toDelegate());

    testInt = ubyte.max;
    assert (!d.consume(consumer2, doNothing));
    assert (testInt == ubyte.max);
    assert (d.consume(consumer1, doNothing));
    assert (testInt == 1);
    assert (!d.consume(consumer1, doNothing));
    assert (d.consume(consumer2, doNothing));
}
