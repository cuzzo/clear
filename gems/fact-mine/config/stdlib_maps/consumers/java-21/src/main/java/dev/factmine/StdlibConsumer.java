package dev.factmine;

import java.util.BitSet;

final class StdlibConsumer {
    static long[] materialize(BitSet values) {
        return values.toLongArray();
    }
}
