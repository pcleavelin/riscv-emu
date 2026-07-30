# Handoff

State of the project as of commit `811047b9` plus the uncommitted work described
under "Done since" below. Written for someone picking this up with no memory of the
sessions that produced it.

## What this project is

A RISC-V emulator turned into a platform for a custom operating system, with none
of the legacy of the IBM PC. Three goals drive the design:

1. A simple platform that is easy to build applications for.
2. Processes communicate by message passing (the actor model).
3. A GUI with an ergonomic API.

## The three layers

The layers map onto the RISC-V privilege model exactly, which is the single most
useful thing to hold in your head:

| RISC-V | here | lives in |
|---|---|---|
| M-mode / SBI | the Odin host emulator | `src/` |
| S-mode | the guest kernel | `os/` |
| U-mode | applications | `apps/`, built against `sdk/` |

The consequence that matters: **`ecall` means two different things depending on
who makes it.** From user mode it traps into the guest kernel's `stvec`. From the
kernel it still leaves the machine for the host, which is the SBI role. The two
syscall numberings therefore never collide.

## Building and running

**Compile only through the nix dev shell.** The toolchain is not on `PATH`, and a
stray `odin` at `~/Documents/personal/odin` is a different, incompatible version.

```sh
nix develop -c sh -c 'make all'        # host emulator + stdlib + kernel
nix develop -c sh -c 'make emu_apps'   # user applications
nix develop -c sh -c './bin/emu'       # boot the VM
nix develop -c sh -c 'odin test src/emu_core/emu_core.odin -file -out:bin/emu_test'
```

Filter the `uncommitted changes` and `evaluation warning` noise lines from nix.

Version control is **jujutsu (`jj`), never git**. Note `main` still points at
`63d2eeb5`, eight commits behind — the bookmark has not been moved all session.
`jj bookmark set main -r @-` when you want it caught up.

## What works today

Booting `./bin/emu` loads `bin/stdlib.elf` and `os/bin/kernel.elf`, enters the
kernel in supervisor mode, and runs to a clean halt.

Along the way it turns on paging and starts four processes: an in-kernel counter
service, an in-kernel ticker task that drives it, the same counter *again* as a
user-mode process loaded from `apps/bin/counter.elf`, and a second ticker driving
that one. Both counters answer the same protocol and reach 21; neither ticker can
tell which side of the privilege boundary it is talking to. The user process then
exits by syscall and the kernel reclaims it.

Commits, oldest first:

| commit | what |
|---|---|
| `50b53333` | Emulator refactored to a bootloader-style VM |
| `006e753e` | Kernel rename; runtime split from app; typed messages |
| `11f46d36` | Two-tier process model with fiber tasks |
| `85b26a7b` | Bounded mailboxes with an overflow policy |
| `f4124b49` | User mode privilege boundary and syscall ABI |
| `4e8c0691` | Sv39 paging and per-process address spaces |
| `38bf0a6f` | User application SDK |
| `811047b9` | Kernel consolidated high; low half freed for processes |

### The emulator (`src/emu_core/emu_core.odin`, one large file)

- RV64IMFDC, plus the privileged subset: CSRs, `sret`, `sfence.vma`, trap delivery.
- `emu_boot(entry)` sets pc, the halt vector in `ra`, and sp; `emu_run` runs to a
  stop. `StopReason` is `None` / `Halt` / `Trap` / `Invalid`.
- Memory is three layers: `phys_read_*` / `phys_write_*` are sparse RAM addressed
  **physically**; `emu_translate` walks Sv39; `emu_read_*` / `emu_write_*` are what
  the guest sees. `emu_fetch_u16` translates with execute permission.
- Full three-level Sv39 walk with superpage leaves, R/W/X/U permission checks and
  the SUM bit. Page frames are 4KB.

### The kernel (`os/`, package `kernel`)

| file | what |
|---|---|
| `kernel.odin` | `_start`, the process model, mailboxes, the scheduler |
| `vm.odin` | kernel memory map, page tables, `paging_init`, `map_page` |
| `trap.odin` | trap handler, syscall dispatch, `copy_from_user`/`copy_to_user` |
| `trap.S` | trap entry/exit, user mode entry, CSR accessors, SUM window |
| `switch.S` | `ctx_switch` for fibers |
| `sbi.odin`, `sbi.S` | supervisor ecalls out to the host; fetching app images |
| `loader.odin` | ELF64 loader: an image becomes an address space |
| `grant.odin` | memory grants: blocks that move between processes |
| `boot.odin` | which processes the system starts with, and on which side |
| `app_counter.odin`, `app_ticker.odin` | in-kernel example processes |

**The process model.** A process is an actor. Three kinds differ in where they run
and who owns the loop:

- **Service** — in the kernel, stackless, run-to-completion. The kernel calls
  `on_message` once per message; state that outlives a message lives in an opaque
  `user_state` pointer. Cheap, and the right shape for a driver.
- **Task** — in the kernel, on its own stack as a fiber, so its state lives in
  ordinary locals and it can suspend mid-computation with `recv`/`yield`.
- **User** — in user mode, in an address space of its own, loaded from its own ELF.
  It reaches the kernel only by syscall.

Lifecycle is `Ready ⇄ Waiting → Dead`. A send into a waiting process wakes it. A
task that returns from its entry, or a user process that exits or faults, becomes
dead and its arena is dropped whole.

**A user process is a fiber on the kernel side**, and this is the load-bearing
idea in the whole design. The stack it traps onto *is* a fiber stack, so the trap
frame of a syscall in progress lives there. A syscall that blocks therefore just
calls `ctx_switch` to the scheduler mid-handler and resumes later exactly where it
was — the same machinery `recv` already used for tasks, with nothing to copy aside
and no saved frame in `Process`. `SYS_RECV` is four lines because of it.

The scheduler runs `.Task` and `.User` through one arm; the only difference is that
a user process gets `satp` pointed at its own root first, since the trap handler
does not change `satp` and `copy_*_user` only resolves in the process's own map.

**Mailboxes** are a fixed ring of 16 slots with tag and payload stored inline
(16-byte tag, 64-byte payload), so a send neither allocates nor leaves anything to
free. Overflow policy is per-process: `RejectNewest` is the default and reports
the refusal so a sender can retry; `DropOldest` is opt-in for state and telemetry.
Losses are counted and reported, never silent.

**Grants** (`os/grant.odin`) are how anything bigger than 64 bytes travels. A grant
is a block of memory that **moves**: the sender allocates it, fills it, sends it,
and at that moment stops being able to reach it. Exactly one process can touch a
grant at any time, so the actor model's promise holds for bulk data too — nothing
to lock, nothing to race, and a sender that keeps using the buffer takes a page
fault instead of silently corrupting the receiver's view.

The mechanics: a grant owns a list of frames (not necessarily contiguous — the
pool hands out single frames). Transfer unmaps them from the sender and marks the
receiver as owner; the receiver calls `grant_map` to get an address. Slots in the
`0x3000_0000` region are the kernel's to hand out, so neither side negotiates an
address, and both usually see it at the same one. A send checks the transfer can
work *before* queueing and commits only once delivery is certain, so a refused
send leaves the sender still holding the memory, mapped where it was — retry is
safe.

Grants are user-to-user. A kernel-resident process has no page table to map one
into, and its frames are not contiguous in the identity map, so `grant_transfer`
refuses. A kernel-side compositor would need a mapping window above `KERNEL_BASE`.

**Kernel memory map** (constants in `os/vm.odin`):

```
0x8000_0000  kernel image      512K, reserved by os/kernel.ld
0x8008_0000  stdlib runtime    512K, reserved by stdlib/link.ld
0x8010_0000  kernel heap       256MB, an arena, grows up
0x9010_0000  frame pool        256MB, 4KB frames, handed out and taken back
0xC000_0000  kernel stack      grows down (EMU_STACK_TOP)
```

`paging_init` identity-maps exactly that one 1GB superpage, supervisor-only.
Everything below `0x8000_0000` is unmapped and belongs to processes.

**Frames come from a pool, not the heap**, because they have to come back: the page
tables and pages of a dead process are the bulk of what it owned, and the heap is an
arena that can only be freed all at once. Free frames are on a list threaded through
themselves — each holds the next one's address in its first eight bytes — so
tracking them costs no memory and freeing one is two stores. Anything never yet
freed comes off a bump pointer, so the pool costs only what has been touched, which
matters because the machine's physical memory is far smaller than the region
reserved.

Two checks keep it honest, and both would fail loudly rather than quietly leak.
`frame_pool_check` at boot frees a frame and asserts the next allocation returns
that same frame, because the counters alone would not notice a broken free list —
they would keep tallying while every allocation came off the bump pointer and the
pool grew forever. `frame_pool_report` at shutdown asserts that every frame ever
taken is either in use or on the free list, which catches a double free (the frame
appears twice) or a cycle (the walk runs past the number of frames that exist).

### The SDK (`sdk/`)

`sdk/abi` (package `abi`) is the contract **both** the kernel and apps import, so
syscall numbers and struct layouts exist in exactly one place. `sdk/app` (package
`app`) is the surface apps are written against, deliberately mirroring the
kernel's actor API so a kernel-resident driver and a user app read alike.

An application is boilerplate-free. `sdk/app/start.odin` owns `_start` and brings
the allocator up over the heap the kernel maps, then calls `app_main`, which is
declared with Odin's calling convention and so inherits a working context:

```odin
package main

import "../../sdk/app"

@(export)
app_main :: proc() {
    app.log("counter: ready\n")
    app.run_service(on_message)
}

on_message :: proc(msg: app.Message) {
    switch msg.tag {
    case "inc": state.count += 1
    case "get": app.send_value(msg.from, "value", state.count)
    }
}
```

`apps/counter` builds to a standalone ELF at `apps/bin/counter.elf`, text and entry
at `0x10000`. It links its own copy of `do_syscall`, because the kernel's is not
reachable from user mode. Do not hardcode the entry point anywhere — the loader
reads `e_entry`, and it moves when the app's code changes.

The user address space, from `sdk/abi`:

```
0x0001_0000  image        text, rodata, data, bss
0x2000_0000  heap         1MB, the SDK's arena
0x3000_0000  grants       8 slots of 1MB, mapped as grants arrive
0x4000_0000  stack top    64K, grows down
```

## Done since `811047b9` (uncommitted at the time of writing)

Step 3b is finished: applications load from their own ELFs at runtime and run as
scheduled user processes.

**Two SBI calls fetch image bytes.** `SBI_IMAGE_SIZE` (`0x20`) and
`SBI_IMAGE_READ` (`0x21`) are in the host's `eval_ecall`. An image is named, not
pathed: `counter` resolves to `apps/bin/counter.elf` under `IMAGE_DIR`, and a name
containing `/`, `\` or `.` is refused, so a guest cannot walk out of that
directory. Bytes are cached in `e.image_cache`, which is what makes the size a
read sees identical to the size already reported. The guest side is `os/sbi.S`
(one `sbi_call` stub that shuffles the C ABI's registers into the SBI's) plus
`image_size` / `image_read` / `image_load` in `os/sbi.odin`.

**The ELF loader.** `load_image(name)` in `os/loader.odin` returns a `LoadedImage`
— a root page table and an entry point. It validates ELF64/RISC-V/ET_EXEC (nothing
relocates), then for each `PT_LOAD` allocates a frame per page, copies the
file-backed part, and maps it at `p_vaddr` with `PTE_U` plus flags from `p_flags`.
Frames start zeroed, so bss costs nothing extra. The heap and stack the SDK's
`_start` assumes are mapped anonymously. Two constraints:

- The loader fills frames through the identity map, before any satp switch, so it
  never needs the SUM window. That is the reason `frame_paddr` exists.
- Nothing merges two segments that share a page, so segments must be page-aligned
  and ascending. The app link script aligns every section, and an `assert` in
  `load_image` catches an image that does not.

**The user boundary is real.** `copy_from_user` / `copy_to_user` in `os/trap.odin`
are the only two places the kernel dereferences a process's pointer. Both go
through `user_range_ok`, which refuses a range that wraps, that is not entirely
below `KERNEL_BASE`, or that has any page not mapped in *that process's* root with
`PTE_U` and the access it needs — using `walk` in `os/vm.odin`. A bad pointer costs
the process an `ERR_FAULT` and nothing else. Message payloads and log strings are
copied, and `SYS_SEND`'s lengths are treated as claims and bounds-checked.

The kernel now dispatches on the `sdk/abi` numbers rather than its own, so all
eight syscalls the SDK promises exist: exit, yield, send, recv, try_recv, spawn,
log, self.

**Scheduling.** `spawn_user(k, "counter")` loads an image and registers a `.User`
process. See the process-model notes above for why it is a fiber, which is the one
design decision here worth understanding before changing anything.

Two supporting changes that are easy to miss:

- **The trap frame carries `sepc` and `sstatus`** (34 slots, not 32). A blocking
  syscall lets other processes run, and their traps overwrite both CSRs, so the
  frame's copy is the one that matters. `trap_handler` therefore advances
  `frame.sepc`, never the register, and `csr_write_sepc` is gone.
- **A user fault kills the process, not the machine.** `trap_handler` checks `SPP`
  in the saved `sstatus`; a fault from user mode calls `exit_current`, which marks
  the process dead and switches to the scheduler for good.

Verified by temporarily making the app store to `0x8010_0000`: the kernel printed
`process 2 faulted, cause=15 stval=80100000 -- killing it`, and the other three
processes ran on to a clean halt. Worth turning into a permanent `apps/rogue` so it
is a regression test rather than a thing someone once checked.

**A dead process's address space is reclaimed.** `process_free` calls
`free_address_space`, which walks the root and frees the leaf frames and the tables
that map them. Only the entries below `KERNEL_BASE` are the process's: the ones
above were copied from `kernel_root` by `create_address_space` and are shared by
every address space, so following them would free the kernel out from under itself.
The scheduler puts `satp` back on the kernel's root before calling this, which it
must, because those are the mappings the process was running on.

The loader's staging buffer no longer leaks either. It rolls the arena's offset back
once the segments have been copied out, which is safe precisely because everything
the loader keeps comes from the frame pool instead of the arena.

Measured on the standard boot: **347 frames at peak, 1 in use at the end** — the one
being `kernel_root`. The 346 reclaimed are exactly what the user process owned: 69
for the image, 256 for its 1MB heap, 16 for its 64K stack, and 5 page tables.

**Grants work.** `apps/pixels` is one image started twice: one process paints a
64×64×4 frame (16K, so 256× the inline message limit) into a grant and hands it
over, the other maps it, checks every pixel, and hands the buffer back so the
painter can draw the next frame into it. Three frames go round.

That round trip is not incidental — it *is* what transfer semantics cost. Because
a grant belongs to exactly one process, a client redrawing the same buffer has to
be given it back first, so the frame loop is paint → hand over → verify → hand
back. Each frame's pattern is shifted by its frame number and checked against the
number the message carried, so a buffer that was not really re-transferred would
show up as a whole frame behind rather than as plausible-looking pixels.

Verified by temporarily writing to the buffer after the handover: the painter took
`cause=15 stval=30000000` and was killed alone, the display still got the frame
intact, and the frame accounting still balanced — the painter died while the
*display* owned the grant, so `grants_release` had to skip a grant it no longer
owned and `free_address_space` had to not collect the transferred frames.

## What to do next

Nothing is blocked. In rough order of value:

1. **Preemption.** Scheduling is cooperative, so a user process that never makes a
   syscall never gives up the CPU. Nothing generates timer interrupts yet.
2. **A leaner logging path.** The counter app's text is ~240KB, nearly all Odin
   runtime pulled in by `fmt`.
3. **Process supervision**, which is where the mailbox-deadlock question below
   wants to be settled.
4. **A kernel-side grant window**, if the GUI compositor ends up kernel-resident.
   Grants are user-to-user today for the reason given above.

## Hard-won knowledge

Things that cost real debugging time. Do not rediscover them.

- **The supervisor may never fetch instructions from a `U`-marked page**, whatever
  SUM says, and user mode may never fetch from a non-`U` page. Kernel and user
  code therefore cannot share a page. This is *why* apps must be separately linked
  ELFs — it is not a preference.

- **`sepc` and `sstatus` must live in the trap frame, not just in the CSRs.** Any
  syscall that blocks lets another process trap, which overwrites both. Restore
  them from the frame on the way out, and decide `sscratch` from the `SPP` you just
  restored rather than from the live register.

- **`C.ADDW` was missing from the compressed decoder**, which surfaced as
  `VM halted: Invalid` the first time an app did 32-bit addition in a hot loop.
  The CA-format group is complete now (`C.SUB`/`C.XOR`/`C.OR`/`C.AND` and
  `C.SUBW`/`C.ADDW`), but if the guest ever dies as `Invalid` again, suspect a
  missing instruction before suspecting the guest. `emu_run` now prints the pc and
  privilege on an undecodable instruction; `riscv64-none-elf-objdump -d` on the
  image tells you which one and in whose function.

- **The SYSTEM opcode `0b1110011` originally decoded to `ECALL` unconditionally**,
  so every `csrrw`, `sret` and `ebreak` was silently a syscall. Fixed in
  `decode_rv64_system`, which splits by `funct3`. If you add privileged
  instructions, extend that function — `sfence.vma` needed a `funct7` check
  because its operands live in `rs1`/`rs2`.

- **`sscratch` convention: it holds the kernel stack while user code runs, and
  zero while the kernel runs.** The trap entry originally swapped unconditionally,
  which is only correct for a trap from user mode; a supervisor-mode fault found
  zero, built its frame at `0xffff_ffff_ffff_ff00` and raised a second fault that
  hid the first. `trap_entry` now branches on the swapped value, and the exit path
  picks the value by `SPP` and restores `sp` last.

- **A process's task stack must be well under `PROCESS_ARENA_SIZE`.** They were
  once equal, the stack consumed the whole arena, mailbox `append` failed
  *silently*, and the receiver blocked forever with no diagnostic. There is an
  assert in `deliver` now.

- **Page fault delivery is precise for a fetch but approximate for a load or
  store** — the instruction may already have written a register. Faults are
  recorded in `fault_pending` and delivered by `emu_step`. Good enough to detect
  and report; not good enough to resume from. Revisit if demand paging ever
  matters.

- **The kernel heap base is not `__bss_end`.** `stdlib.elf` links at `0x8008_0000`
  and would collide. It is `0x8010_0000`, immediately past both reserved regions.

- A user link script must stub `__tls_get_addr`; Odin's random generator
  references it and nothing ever calls it.

- Odin tolerates unused imports here, so `base:runtime` and `core:math/bits` sit
  unused in `emu_core.odin`.

- The `-rm` lines in the Makefile fail noisily on a clean tree. Harmless; make
  marks them ignored.

## Decisions already made — do not relitigate

- **Kernel in the guest, not the host.** Chosen for a real OS over a faster path
  to running apps.
- **Order was 3a syscalls → 3c paging → 3b loading.** Worth knowing that 3c and 3b
  turned out coupled: isolation is not demonstrable until apps are separate ELFs,
  for the fetch-permission reason above.
- **Sv39, brought up identity-mapped**, so a working system proved the walker
  before processes got distinct maps.
- **`RejectNewest` is the default overflow policy**, because it never destroys a
  message the system already accepted and makes failure actionable at the sender.
  Blocking sends were rejected as a default: a service is stackless and physically
  cannot block, and blocking invites deadlock between two full mailboxes.
- **Messages stay small and inline.** Anything larger than 64 bytes travels as a
  grant, not in a bigger mailbox.
- **A grant moves rather than being shared.** Chosen over shared mapping because it
  keeps the actor model's no-shared-mutable-state invariant, which is what makes
  message passing worth building on: no locks, no races, and misuse faults instead
  of corrupting. Sharing can be added later as a second mode, once a compositor
  exists to say what it actually needs.
- **App ELF bytes come from an SBI hypercall**, not an embedded archive.
- **A user process is hosted by a kernel fiber**, rather than the kernel keeping a
  saved trap frame per process and re-entering user mode from the scheduler. It
  costs one 16K kernel stack per process and buys blocking syscalls for free,
  because the in-progress frame simply stays on that stack. This is how real
  kernels do it, and it is why `SYS_RECV` needed no new machinery.
- **The kernel dispatches on `sdk/abi`'s syscall numbers.** It briefly had its own
  `SYS_PRINT`/`SYS_EXIT` pair, which defeated the point of a shared contract.

## Open questions

- **Grants are one-shot handovers, not shared buffers.** `apps/pixels` shows what
  that costs: a client redrawing the same buffer must be handed it back each time,
  so every frame is a round trip of two messages rather than one. Whether that
  matters is a question for a real compositor — a shared mode would remove the
  return leg but needs a synchronization story the kernel does not have.
- **Bounded mailboxes plus blocking retry loops can deadlock** if two processes
  fill each other's mailboxes. Inherent to reject-newest; normally handled with
  timeouts or supervision. Worth settling when process supervision is designed.
- **Scheduling is round-robin and cooperative.** A user process that never makes a
  syscall never gives up the CPU, because nothing generates timer interrupts yet.
  Preemption is the fix and is untouched.
- **The frame pool never returns memory to the heap**, and its bump pointer never
  walks back, so the pool's high-water mark is permanent. Fine while frames are
  reused; it would matter if something allocated frames in bursts.

Settled by this session's work, kept for the reasoning:

- **The service/task split did collapse in user mode**, as expected: a U-mode
  process inherently owns a stack and its control flow. The model is now
  "in-kernel service, in-kernel task, user process", and stackless services survive
  exactly where predicted — kernel-resident drivers and the future GUI compositor.
  `os/boot.odin` runs the same counter both ways, which is the clearest reading of
  what the distinction now costs and buys.
