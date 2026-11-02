# 1. Latency vs. throughput 

what they are and when each dominates?
Latency is equal time from byte-arrival to visible result, at small sizes.
In a terminal it's the echo path, when pressing `a`, the app writes back as 
`\x1b[?a`, plus maybe a repaint dirty cell for displaying the char `a`, a 
few hundred bytes. What matters is the one-shot cost, parser call settup, 
one transition/step, one print call, then the renderer's frame deadline (16.6ms @60HZ).

The throughput is equal sustained bytes/sec on bulk output. a `cat` of 500MB log,
`find /`, compiler spew, `vim` redrawing a large screen. This is where the throughput 
number of parser live.

So, when is the case of those will dominates:
1. workload: typing in a shell
   regime: latency
   binding_constraint: scheduler wakeup + frame deadline; parser µs are invisible.

2. workload: `cat file.log`, `find /`
   regime: throughput
   binding_constraint: pty buffer drain rate, backpresure on writer.

3. workload: `htop`, `vim`, fullscreen TUIs
   regime: mixed
   binding_constraint: burst throughput and frame latency at refresh.

4. workload: huge DCS/OSC payloads (sixel, kitty images)
   regime: throughput
   binding_constraint: payloadEnd/dcsPut parser dispatch rate

5. workload: paste-bracketed big (size MB) paste
   regime: throughput
   binding_constraint: one burst, latency of the last byte

A subtlety, interactive feel is really a latency tail problem. A 100µs 
parser call is invisible alone, but if it delays the frame containing 50 
other echoes past the vsync deadline, the user sees a dropped frame. So
latency work is abouot worst-case (p99), throughput about sustained rate.

# 2. Who regresses each one

* O(n) or O(n²) work per event.
* Unbounded per-call work, feeding the renderer or grid per byte instead of 
batching.

* Syscalls per byte: `read()`/`write()` per byte in the pty loop, or flushing 
the renderer pe event instead of per batch.

* Allocation in the hot: allocating for params or sequences on each dispatch
adds p99 jitter even when averages look fine.

On tail-latency performance analysis, primarly in a latency-sensitive 
"hot path", avoid repeatedly creating temporary parameter arrays, lists, 
or sequencee object if possible.

Creating new objects or buffers every time a task is dispatched can make 
the slowest requests noticeably slower, even if the average time barely 
changes.

A dispatch is the moment a system hands a work to a worker, function, or 
device. If dispatch allocates memory for its parameters or for a sequence 
of items, that allocation adds extra work. Even with fast alloc, but some
can trigger slower events, because of such as garbage collection, allocator
synchronization, memory growth, or cache misses. Those occasional delays 
will show up in thte p99 latency, the time within which 99% of dispatches 
finish. The average can still look fine because the slow dispatches are rare
but hurts the most.

As an example, suppose nearly all dispatches take 1ms, but 1 in 100 task takes
8ms because it triggers cleanup or contends for allocator resources. The average 
may stay near 1 ms, while p99 reflects the much slower tail.

# 3. How to measuer latency

* Round-trip time (RTT): `clock_gettime` before writing a keystroke-response
sequence to the pty and after the parser, screen, renderer consume it. This is
the "echo" latency users feel; studies put noticeable latency around >50ms, 
good terminals under ~10ms.

* Per-event const vt/ansi parser, time a call on a small input, not per byte.
A 20-byte `CSI H` should cost hunderds of ns total, dominated by cache misses,
not instruction count.

* p99/tail specifically: latency is about worst-case, not median. Track max 
and p99 for each sample, not just min/p50.

* End-to-end: tme from pty read() returning bytes to the frame being committed. 
Tooling-wise, the closest practical method is timestamping around the 
feed->dispatch->renderer boundary.

## What backpressure does? what causes it?

Backpressure means the producer has to slow down cause the consumer can't accept
data as quickly as it's being produced. In a PTY, if the application writes output
faster than the terminal emulator reads it, the kernel's PTY queue fills. The
application's write may then block or proceed more slowly. The impact is usually 
increased latency or a stalled producer, not lost data.

The PTY is where the queue fills, but it's usually not the root cause.
The root cause is somewhere downstream, the emulator may be slow to read,
vt/ansi parser, update its screen, or render frames. Scheduling delays or
a slow application reading input can also contribute. A renderer's frame 
buffer matters only if the emulator's rendering pipeline prevents it from 
continuing to drain the PTY. A design that keeps reading and queues rendering 
work separetly (dedicated threads) can reduce that coupling, though its own
queues can eventually fill too.

A useful way to locate the bottleneck is to compare bulk output that the 
emulator reads but doesn't render with output that it renders normally.
A big difference points toward parsing or rendering; simlar slowdowns suggest
the PTY reader, scheduling, or another part of the I/O path.

## Why Vim may struggle with a big file

That's generally Vim's file-handling and memory use, not a limit on the 
terminal emulator's buffer. Vim reads the file from storage inito its own
editing buffer. Thee terminal carries Vim's screen updates and keystorkes; 
It doesn't store the whole file.

Vim can struggle when the file is very large, has extremely long lines, or 
when features such as syntax highlighting, plugins, folding, or swap-file 
handling add substantial work or memory use. The terminal emulator can make 
displaying lots of screen output slow, but it normally doesn't determine how
large a file Vim can load.