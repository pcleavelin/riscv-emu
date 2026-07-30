package kernel

// Preemption: taking the CPU back from a process that will not give it up.
//
// Everything else in the scheduler is cooperative. A task yields, a service
// returns, a user process makes a syscall -- each of those is a moment the kernel
// gets control back because the process handed it over. A user process that simply
// computes hands nothing over, and under cooperative scheduling alone it would run
// until it was finished and every other process would wait. That is fine for the
// kernel's own fibers, which are code this system trusts, and not fine for an
// application, which is code it does not.
//
// So the timer interrupts user code and only user code. The kernel runs with
// sstatus.SIE clear, which means an interrupt is never taken while the kernel is
// working: there is no reentrancy to reason about, and no critical section that
// needs a lock to protect it. The one place control leaves a user process
// involuntarily is the trap handler, which is where it already leaves voluntarily.
//
// Preempting costs nothing new because a user process is a fiber. Its trap frame
// is already on its own kernel stack, so being preempted is the same ctx_switch a
// blocking syscall does, and resuming is the same return.

// The timer's bit in sie, and how scause reports the interrupt.
SIE_STIE :: u64(1) << 5
CAUSE_INTERRUPT :: u64(1) << 63
IRQ_S_TIMER :: u64(5)

// How long a process runs before the kernel takes the CPU back, measured in the
// machine's ticks -- one per instruction retired. Small enough that a spinning
// process does not visibly stall the others, large enough that the handler is not
// most of the work.
TIME_SLICE :: 20_000

// How many times the timer has taken the CPU from a process. Nothing depends on
// it; it is here so that preemption is visible rather than merely believed.
preemptions: int

// Start the timer. Until this runs the timer bit is disabled, so the interrupt is
// never recognised however often the deadline passes.
timer_init :: proc() {
    csr_set_sie(SIE_STIE)
    timer_rearm()
}

// Set the next deadline a full slice out. This is also what acknowledges the
// interrupt that just fired -- without it the pending bit would send the machine
// straight back into the handler.
timer_rearm :: proc() {
    sbi_set_timer(sbi_time() + TIME_SLICE)
}
