# Working context

Written for Claude, resuming this project with no memory of the sessions that
produced it. Read **Orientation**, **Working agreements** and **Tooling notes**
before touching anything; the rest is reference, findable by heading.

**Where things go when you learn something:**

| what you learned | where it goes |
|---|---|
| a fact about the system as it is now | *The system* |
| something that cost debugging time | *Hard-won knowledge* |
| a quirk of a tool, command or compiler | *Tooling notes* |
| a choice with reasons, that should stick | *Decisions* |
| something undecided or unmeasured | *Open questions* |

Keep this file honest. If a measurement here is stale, re-measure or delete it —
a confidently wrong number is worse than no number. Several claims in here were
wrong once and are now marked with what actually happened.

---

## Orientation

A RISC-V emulator turned into a platform for a custom operating system, with none
of the legacy of the IBM PC. Three goals drive the design:

1. A simple platform that is easy to build applications for.
2. Processes communicate by message passing (the actor model).
3. A GUI with an ergonomic API.

### The three layers

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

### What works today

Booting `./bin/emu` loads `bin/stdlib.elf` and `os/bin/kernel.elf`, enters the
kernel in supervisor mode, turns on paging, and runs to a clean halt in about
three seconds. It starts eight processes:

- An in-kernel counter service and an in-kernel ticker task driving it.
- The same counter *again* as a user process from `apps/bin/counter.elf`, with a
  second ticker. Neither ticker can tell which side of the privilege boundary it
  is talking to — though since preemption the two no longer run in step, which is
  why the user counter finishes at 22 rather than 21 and its burst is refused
  differently. Both are correct; the interleaving differs and reject-newest
  reports every refusal either way.
- Two `apps/bin/pixels.elf` processes passing a 16K frame back and forth as a
  grant.
- `apps/bin/gfx.elf` drawing 24 animated frames to the display.
- `apps/bin/spin.elf`, which never yields, to be preempted.

Each user process exits by syscall and the kernel reclaims everything it owned.

### Where the work stands

`main` is at `63d2eeb5`. The bookmark `user-processes` is on `origin` at
`baca3efd`. **Everything after that is committed locally and deliberately not
pushed** — see *Working agreements*.

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
| `8ac1d5a7` | Fetch application images from the host over the SBI |
| `70070fa5` | Load an application ELF into an address space of its own |
| `e31d6662` | Run applications as scheduled user processes |
| `5e2af5d9` | Reclaim a dead process address space from a frame pool |
| `0534ad03` | Hand memory between processes with grants |
| `8d955f8c` | Decode the compressed add-word instruction |
| `baca3efd` | Pass the pixel buffer back and forth ← `user-processes` on origin |
| `e78b41b4` | Preempt user processes with a timer interrupt |
| `695495ee` | Clear and copy pages with the assembly memory routines |
| `1ebb65a1` | Build the kernel and the applications optimized |
| `f7a0a43c` | Give the machine a display |

---

## Working agreements

- **Version control is jujutsu (`jj`), never `git`.**
- **Never push.** Commit locally, say what is unpushed, and stop. One request to
  push covers that push and nothing later. Same for anything else outward-facing.
- **Comments describe the code as it is**, never how it got there. No "previously",
  "changed from", "now uses". A comment should read the same whether written by the
  original author or someone meeting the code fresh.
- Prose style: concise, information-dense, no filler or marketing tone.

---

## Tooling notes

Quirks that cost time. Read before reaching for a tool.

### Building and running

**Only through the nix dev shell.** The toolchain is not on `PATH`, and a stray
`odin` at `~/Documents/personal/odin` is a different, incompatible version (it is
still useful to *read* — see *Odin* below).

```sh
nix develop -c sh -c 'make all'        # host emulator + stdlib + kernel
nix develop -c sh -c 'make emu_apps'   # user applications
nix develop -c sh -c './bin/emu'       # boot the VM, display in the terminal
nix develop -c sh -c './bin/emu --quiet'   # no display, log only
nix develop -c sh -c 'odin test src/emu_core/emu_core.odin -file -out:bin/emu_test'
```

- Filter the `uncommitted changes` and `evaluation warning` lines nix prints.
- `ld: cannot find entry symbol _start` when linking `stdlib.elf` is **pre-existing
  noise**, not a new breakage.
- The `-rm` lines in the Makefile fail noisily on a clean tree. Make ignores them.
- **Apps are an input to the kernel at runtime and nothing detects staleness.**
  After any checkout, run *both* `make all` and `make emu_apps`. A stale
  `apps/bin/*.elf` produces a wrong run that looks plausible — this cost real time
  once, when an old counter image never replied `stop` and a ticker spun forever
  looking like a hang in freshly written code.
- A failed app link leaves **no** `.elf`, and the next run silently starts with
  zero user processes and finishes in a second. If a run gets suspiciously fast,
  check the frame count in the shutdown line before believing it.

### jujutsu

- `jj split -m "MSG" <paths>` — **always pass `-m`**. Without it, jj opens `nano`,
  which fails in this environment (the split is aborted cleanly, nothing is lost).
- **`jj split` puts the selected paths in the *first* (parent) commit.** The
  remainder becomes the new working copy and keeps the original description. So
  select the *earlier* concern, then re-describe what is left.
- `jj describe --stdin <<'EOF' ... EOF` for multi-line messages. Avoids every
  quoting problem; `-m "$(...)"` also works for copying an existing description.
- **`jj op restore <op-id>`** undoes a botched operation. `jj op log` lists them.
  This rescued four commit messages that a bad `awk` pipeline had flattened into
  single lines.
- **Change IDs are stable across rewrites; commit IDs are not.** Loop over change
  IDs when rewriting a series.
- To build-test an older commit: `jj new <rev>`, build, then `jj abandon` and
  `jj edit <tip>`. Remember to rebuild everything afterwards.
- **A file with hunks belonging to two concerns cannot be split by path.** The
  reliable move: revert the later concern's hunks by hand, `jj split` the earlier
  one out, then re-apply. Fiddly but it keeps history honest, and it has been
  needed for `Makefile`, `os/kernel.odin` and `os/sbi.odin`.

### Shell and CLI

- `grep --include=*.odin` **fails in zsh** — the glob is expanded before grep sees
  it. Quote it, or name directories instead.
- `cat -A` does not exist on macOS. Use `awk` to show line structure.
- BSD `sed -E` chokes on alternation written `(a|b|c)` inside a substitution
  address. **For any multi-file or structured edit, write a short Python script**
  rather than fighting sed.
- **Never pipe a long-running command through `tail`/`head`.** The pipe buffers
  until EOF, so a running program looks hung and its output is invisible. Redirect
  to a file in the scratchpad and inspect that.
- **A pipeline's `$?` is the last command's.** `cmd | grep ...` reports grep's
  status, so a failed build reads as success. Capture the real exit code:
  `cmd >log 2>&1; echo $?`.
- Time a run with `s=$(date +%s); ...; echo $(( $(date +%s) - s ))s`.

### Odin

- **The compiler emits its own `memset`/`memcpy` into the kernel object and they
  win at link.** They are byte-at-a-time. See *Hard-won knowledge*; this was ~88%
  of boot time.
- **A `foreign` declaration and a definition of the same symbol cannot coexist in
  one object.** At `-o:none` each package is its own object and the linker joins
  them, so it works; at `-o:speed` the whole program is one object, the declaration
  wins and the definition is dropped. Do not build cross-package entry points that
  way.
- **`@(link_name = "x", linkage = "strong", require)`** is the pattern for a symbol
  something outside Odin must find. It is what Odin's own runtime uses to define
  `memset`. `@(export)` alone does not survive optimization; `@(require)` alone
  keeps the body but leaves it local and mangled.
- **Object layout differs by optimization level.** `-o:none` emits one object per
  package (`kernel-runtime-core.o` and friends), `-o:speed` a single `kernel.o`.
  The Makefile globs `kernel*.o` / `counter*.o` so both work.
- There is **no flag to disable dead-code elimination**. Checked.
- **Read the Odin source when an attribute is in doubt** — `~/Documents/personal/odin`
  is a full checkout. `base/runtime/procs.odin` is where the `memset` pattern above
  came from. Faster and more reliable than guessing attribute combinations, which
  wasted several build cycles here.
- Odin tolerates unused imports, so `base:runtime` and `core:math/bits` sit unused
  in `emu_core.odin`.
- `defer` fires at the end of its *enclosing block*, not the function. A `defer`
  inside an `if` runs immediately at the end of that `if`.

### Verifying a change

The system has invariants that catch regressions on their own. Prefer them to
eyeballing output:

- **Frame accounting.** The shutdown line `frames N in use, M free, P at peak`
  comes from `frame_pool_report`, which asserts that every frame ever taken is in
  use or on the free list, and that the free list has no cycle. `frame_pool_check`
  at boot separately frees a frame and asserts the next allocation returns that
  same one — the counters alone would not notice a broken free list, since every
  allocation would quietly come off the bump pointer while the pool grew forever. A double free or a leak fails loudly. Expect
  `1 in use` at the end — that one is `kernel_root`.
- **Determinism.** Time is counted in instructions, so two runs must be
  byte-identical. `diff` them. This is the cheapest possible check that a change
  did not introduce nondeterminism.
- **The pixels app checks every byte** of a 16K grant against the frame number it
  was told, so a stale or unmoved buffer shows as a whole frame behind rather than
  as plausible pixels.
- **Provoke the failure to prove the guard.** Isolation claims were verified by
  temporarily making an app store to a kernel address, and grant-transfer semantics
  by touching a buffer after handing it over. Both produced the expected fault,
  killed only that process, and were then reverted. Do this rather than asserting
  a guarantee holds.
- **To actually look at the display**, capture stdout and reconstruct it: frames
  are separated by `\e[H`, each cell is
  `\e[38;2;R;G;Bm\e[48;2;R;G;Bm▀` carrying the top and bottom pixel of a row pair.
  A short Python script can rebuild the framebuffer and write a PNG with `zlib` and
  `struct` alone (no PIL needed), which is how the first frame was checked.

### Debugging the guest

- **`VM halted: Invalid` means a missing instruction before it means a broken
  guest.** `emu_run` prints the pc and privilege; run
  `riscv64-none-elf-objdump -d` on the image to see which instruction and in whose
  function. This is how `C.ADDW` was found missing.
- `riscv64-none-elf-nm` on `os/bin/kernel.elf` and `bin/stdlib.elf` answers "which
  definition actually won" — lowercase letters are local symbols, `U` is undefined.
- `objdump -d --disassemble=<symbol>` beats guessing an address range; objdump
  otherwise labels addresses with the nearest preceding symbol, which can be a
  much larger enclosing function and is misleading.

---

## The system

### The emulator (`src/`)

`src/emu_core/emu_core.odin` is one large file:

- RV64IMFDC, plus the privileged subset: CSRs, `sret`, `sfence.vma`, trap delivery.
- `emu_boot(entry)` sets pc, the halt vector in `ra`, and sp; `emu_run` runs to a
  stop. `StopReason` is `None` / `Halt` / `Trap` / `Invalid`.
- Memory is three layers: `phys_read_*` / `phys_write_*` are sparse RAM addressed
  **physically**; `emu_translate` walks Sv39; `emu_read_*` / `emu_write_*` are what
  the guest sees. `emu_fetch_u16` translates with execute permission.
- Full three-level Sv39 walk with superpage leaves, R/W/X/U permission checks and
  the SUM bit. Page frames are 4KB.
- One tick per instruction retired is the machine's whole notion of time.

`src/main.odin` is the terminal front end; `src/term` renders the framebuffer.

### The kernel (`os/`, package `kernel`)

| file | what |
|---|---|
| `kernel.odin` | `_start`, the process model, mailboxes, the scheduler |
| `vm.odin` | memory map, page tables, the frame pool, `walk`, `map_page` |
| `trap.odin` | trap handler, syscall dispatch, `copy_from_user`/`copy_to_user` |
| `trap.S` | trap entry/exit, user mode entry, CSR accessors, SUM window |
| `switch.S` | `ctx_switch` for fibers |
| `sbi.odin`, `sbi.S` | supervisor ecalls out to the host |
| `loader.odin` | ELF64 loader: an image becomes an address space |
| `grant.odin` | memory grants, and presenting one to the display |
| `timer.odin` | preemption: the timer that takes the CPU back |
| `boot.odin` | which processes start, and on which side of the boundary |
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

**A user process is a fiber on the kernel side**, and this is the load-bearing idea
in the whole design. The stack it traps onto *is* a fiber stack, so the trap frame
of a syscall in progress lives there. A syscall that blocks calls `ctx_switch` to
the scheduler mid-handler and resumes exactly where it was — the same machinery
`recv` already used for tasks, with nothing to copy aside and no saved frame in
`Process`. `SYS_RECV` is four lines because of it, and preemption needed no new
machinery at all.

The scheduler runs `.Task` and `.User` through one arm; the only difference is that
a user process gets `satp` pointed at its own root first, since the trap handler
does not change `satp` and `copy_*_user` only resolves in the process's own map.

**The loader** (`os/loader.odin`) validates ELF64/RISC-V/`ET_EXEC` — nothing
relocates — then for each `PT_LOAD` allocates a frame per page, copies the
file-backed part, and maps it at `p_vaddr` with `PTE_U` plus flags from `p_flags`.
Frames arrive zeroed, so bss costs nothing. Two constraints hold it together:

- It fills frames **through the identity map**, before any `satp` switch, so it
  never needs the SUM window. That is what `frame_paddr` is for.
- Nothing merges two segments sharing a page, so segments must be page-aligned and
  ascending. The app link script aligns every section, and an `assert` in
  `load_image` catches an image that does not.

**The user boundary is enforced in exactly two places.** `copy_from_user` and
`copy_to_user` in `os/trap.odin` are the only points where the kernel dereferences
a pointer a process gave it. Both go through `user_range_ok`, which refuses a range
that wraps, that is not wholly below `KERNEL_BASE`, or that has any page not mapped
in *that process's* root with `PTE_U` and the access it needs. A bad pointer costs
the process an `ERR_FAULT` and nothing else. Lengths a process claims — message tag
and payload sizes, log lengths, image names — are bounds-checked before they are
believed.

**Mailboxes** are a fixed ring of 16 slots with tag and payload inline (16-byte
tag, 64-byte payload), so a send neither allocates nor leaves anything to free.
Overflow policy is per-process: `RejectNewest` is the default and reports the
refusal so a sender can retry; `DropOldest` is opt-in for state and telemetry.
Losses are counted and reported, never silent.

**Grants** are how anything bigger than 64 bytes travels. A grant is a block of
memory that **moves**: the sender allocates it, fills it, sends it, and at that
moment stops being able to reach it. Exactly one process can touch a grant at any
time, so the actor model's promise holds for bulk data too — nothing to lock,
nothing to race, and a sender that keeps using the buffer takes a page fault
instead of silently corrupting the receiver's view.

A grant owns a list of frames, not necessarily contiguous, because the pool hands
out single frames. Transfer unmaps them from the sender and marks the receiver as
owner; the receiver calls `grant_map` for an address. Slots in the `0x3000_0000`
region are the kernel's to hand out, so neither side negotiates an address and both
usually see it at the same one. A send checks the transfer *before* queueing and
commits only once delivery is certain, so a refused send leaves the sender holding
the memory, mapped where it was — retry is safe.

Grants move only between user processes: a kernel-resident process has no page
table to map one into. **Presenting is different and needs no such window** — the
kernel reads a grant's frames by physical address, page by page, because it is
identity mapped.

**The display** is a device, not an API. The emulator owns a 64×64 RGBA framebuffer
and knows nothing about how it reaches a screen: the front end installs a `show`
procedure, so `src/term` renders half-block characters (two pixels per character
cell, 24-bit colour, works over ssh) and a window front end can replace it without
the guest noticing. Three SBI calls: ask the size, blit a block of physical memory
in, show what arrived. Nothing appears until `show`, so a frame is never seen
half-drawn.

A process draws into a grant and calls `present`, which is deliberately **not** a
send: presenting only reads, so the same buffer is drawn into again for the next
frame, where sending would hand it away.

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
tables and pages of a dead process are the bulk of what it owned, and the heap is
an arena that frees only all at once. Free frames are on a list threaded through
themselves — each holds the next one's address in its first eight bytes — so
tracking costs no memory and freeing is two stores. Anything never yet freed comes
off a bump pointer, so the pool costs only what has been touched.

`process_free` releases a dead process's grants *before* its address space: a
mapped grant's frames are reachable both ways, and the other order frees them
twice.

### The SDK (`sdk/`) and apps

`sdk/abi` (package `abi`) is the contract **both** the kernel and apps import, so
syscall numbers and struct layouts exist in exactly one place. `sdk/app` (package
`app`) is the surface apps are written against, deliberately mirroring the kernel's
actor API so a kernel-resident driver and a user app read alike.

An app carries one piece of boilerplate: it owns `_start` and hands its entry to
`app.start()`, which brings the allocator up over the heap the kernel maps and then
calls it. It reads as ceremony but is load-bearing — see *Odin* in *Tooling notes*.

```odin
package main

import "../../sdk/app"

@(link_name = "_start", linkage = "strong", require)
_start :: proc "c" () {
    app.start(app_main)
}

app_main :: proc() {
    app.log("counter: ready\n")
    app.run_service(on_message)
}
```

`app_main` is declared with Odin's calling convention, so it inherits a working
context and an app never touches `context` itself.

Each app builds to a standalone ELF and links its own copy of `do_syscall`, because
the kernel's is not reachable from user mode. **Do not hardcode an entry point** —
the loader reads `e_entry`, and it moves when the app's code changes.

The user address space, from `sdk/abi`:

```
0x0001_0000  image        text, rodata, data, bss
0x2000_0000  heap         1MB, the SDK's arena
0x3000_0000  grants       8 slots of 1MB, mapped as grants arrive
0x4000_0000  stack top    64K, grows down
```

---

## Hard-won knowledge

Things that cost real debugging time. Do not rediscover them.

- **The supervisor may never fetch instructions from a `U`-marked page**, whatever
  SUM says, and user mode may never fetch from a non-`U` page. Kernel and user code
  therefore cannot share a page. This is *why* apps must be separately linked ELFs
  — it is not a preference.

- **`sepc` and `sstatus` must live in the trap frame, not just in the CSRs.** Any
  syscall that blocks lets another process trap, which overwrites both. Restore
  them from the frame on the way out, and decide `sscratch` from the `SPP` you just
  restored rather than from the live register.

- **Moving memory is the most expensive thing the kernel does.** Starting a process
  cost 29.1M ticks, ~88% of a boot across four processes. Not the host — the SBI
  image read copies 1.3MB in 0.22s. It is the ~1.4MB cleared and ~276KB copied per
  process, going through the compiler's byte-at-a-time routines.

  Disassemble `memset` in `os/bin/kernel.elf`: the inner loop is **13 instructions
  to store one byte**, with the index, length, pointer and fill byte each reloaded
  from the stack and spilled back every iteration. `memcpy` is 14 a byte. The
  assembly in `stdlib/memops.S` stores eight bytes per instruction from a
  32×-unrolled loop — 0.13 a byte, around 100× on the inner loop. It is exported as
  `memset_asm` / `memcpy_asm` because the plain names cannot be taken, and
  `alloc_frame` and `map_segment` call the aliases.

  Multiplying 13 a byte over what one process clears, copies and stages predicts
  26.6M of the 29.1M measured, which is how we know these two routines were nearly
  all of process creation.

  | clearing and copying with | ticks | wall |
  |---|---|---|
  | the compiler's routines | 132.5M | 87s |
  | an inline `u64` loop | 79.0M | 53s |
  | `memset_asm` | 34.8M | 24s |
  | `memset_asm` + `memcpy_asm` | 17.3M | 14s |
  | the same, kernel `-o:speed` | 11.3M | 9s |
  | the same, apps `-o:speed` too | **3.4M** | **3s** |

  Handing the clearing to the host over `SYS_MEMSET` was also tried: 34.0M ticks,
  level with `memset_asm`, because the host pays per byte in page-table walks what
  the guest saves. Not worth a non-standard SBI call.

  **Watch for this whenever a hot path calls `copy()` or clears a buffer.**

- **A foreign declaration cannot name a symbol the same program defines.** The SDK
  used to declare `app_main` as `foreign` while each app `@(export)`ed it. That
  works when packages are separate objects; an optimized build makes one object,
  the declaration wins, and the link fails with `undefined reference to app_main`.
  Fixed by inverting it — the app owns `_start` and passes its entry in. Details
  and the attribute pattern are under *Odin* in *Tooling notes*.

  Optimized apps are also **half the size**, 157KB against 324KB, which cuts the
  frames each costs to load.

  Residual risk: optimization could expose undefined behaviour in code that casts
  integers to pointers, switches stacks behind the compiler's back, or writes page
  tables the hardware reads. Nothing has shown up — the byte-exact grant check
  passes, the frame-pool asserts pass, faults land where provoked, and two runs
  stay identical. Watch anyway.

- **The emulator walks the page tables on every access.** 267M translation calls
  for 132M instructions when measured — about two per instruction, each a fresh
  three-level walk with a map lookup per level. No TLB by design, which is why
  `sfence.vma` has nothing to do.

- **`C.ADDW` was missing from the compressed decoder**, surfacing as `VM halted:
  Invalid` the first time an app did 32-bit addition in a hot loop. The CA-format
  group is complete now. See *Debugging the guest* for how it was found.

- **The SYSTEM opcode `0b1110011` originally decoded to `ECALL` unconditionally**,
  so every `csrrw`, `sret` and `ebreak` was silently a syscall. Fixed in
  `decode_rv64_system`, which splits by `funct3`. If you add privileged
  instructions, extend that function — `sfence.vma` needed a `funct7` check because
  its operands live in `rs1`/`rs2`.

- **`sscratch` holds the kernel stack while user code runs, and zero while the
  kernel runs.** The trap entry originally swapped unconditionally, which is only
  correct from user mode; a supervisor fault found zero, built its frame at
  `0xffff_ffff_ffff_ff00` and raised a second fault that hid the first.

- **A process's task stack must be well under `PROCESS_ARENA_SIZE`.** They were once
  equal, the stack consumed the arena, mailbox `append` failed *silently*, and the
  receiver blocked forever with no diagnostic. There is an assert in `deliver` now.

- **Page fault delivery is precise for a fetch but approximate for a load or
  store** — the instruction may already have written a register. Faults are recorded
  in `fault_pending` and delivered by `emu_step`. Good enough to detect and report;
  not good enough to resume from. Revisit if demand paging ever matters.

- **The kernel heap base is not `__bss_end`.** `stdlib.elf` links at `0x8008_0000`
  and would collide. It is `0x8010_0000`, past both reserved regions.

- A user link script must stub `__tls_get_addr`; Odin's random generator references
  it and nothing ever calls it.

---

## Decisions — do not relitigate

- **Kernel in the guest, not the host.** A real OS over a faster path to apps.
- **Sv39, brought up identity-mapped**, so a working system proved the walker
  before processes got distinct maps.
- **`RejectNewest` is the default overflow policy**: it never destroys a message
  the system already accepted and makes failure actionable at the sender. Blocking
  sends were rejected — a service is stackless and cannot block, and blocking
  invites deadlock between two full mailboxes.
- **Messages stay small and inline.** Anything over 64 bytes travels as a grant.
- **A grant moves rather than being shared**, keeping the no-shared-mutable-state
  invariant that makes message passing worth building on: no locks, no races, and
  misuse faults instead of corrupting. Sharing can be a second mode later, once a
  compositor says what it needs.
- **App ELF bytes come from an SBI hypercall**, not an embedded archive.
- **Time is counted in instructions, not wall-clock**, and the timer is an SBI call
  rather than a memory-mapped CLINT. Cheaper, and it makes runs reproducible.
- **Only user code is preempted.** The kernel keeps `sstatus.SIE` clear, so it is
  never interrupted mid-operation and needs no locks or reentrancy. Kernel fibers
  are trusted to cooperate; applications are not.
- **A user process is hosted by a kernel fiber**, rather than the kernel keeping a
  saved trap frame per process. Costs one 16K kernel stack per process and buys
  blocking syscalls and preemption for free.
- **The kernel dispatches on `sdk/abi`'s syscall numbers.** It briefly had its own
  pair, which defeated the point of a shared contract.
- **The display is a device with a pluggable front end**, so the same machine runs
  in a terminal over ssh or in a window, and the guest cannot tell.

---

## Open questions

- **Grants are one-shot handovers, not shared buffers.** `apps/pixels` shows the
  cost: a client redrawing a buffer must be handed it back, so every frame is two
  messages. Whether that matters is a question for a real compositor; a shared mode
  would remove the return leg but needs a synchronization story the kernel lacks.
- **Bounded mailboxes plus blocking retry loops can deadlock** if two processes
  fill each other's mailboxes. Inherent to reject-newest; normally handled with
  timeouts or supervision.
- **Scheduling is preemptive only for user code.** A kernel task that spins still
  stops the machine — deliberate, but it means a buggy in-kernel driver is a hang.
- **Almost none of the machine's time is application code.** Even at 3s, what
  remains is mostly process creation.
- **The frame pool never returns memory to the heap** and its bump pointer never
  walks back, so the high-water mark is permanent. Fine while frames are reused.
- **Nothing carries input events**, and where they enter the actor model is
  undesigned.

Settled, kept for the reasoning:

- **The service/task split did collapse in user mode**, as predicted: a U-mode
  process inherently owns a stack and its control flow. The model is now
  "in-kernel service, in-kernel task, user process", and stackless services survive
  exactly where expected — kernel-resident drivers and a future compositor.
  `os/boot.odin` runs the same counter both ways.
- **A kernel-side grant window is not needed for presenting.** Reading a grant's
  frames physically, page by page, is enough. It would only be needed if a
  kernel-resident process had to *receive* a grant.

---

## What to do next

Nothing is blocked. In rough order of value:

1. **The raylib front end.** The display abstraction is in place and the terminal
   backend proves it; a window is a second `show` procedure. Odin's `vendor:raylib`
   binding links `system:raylib` and nixpkgs has raylib 6.0, so this is a flake
   change plus a second main package. The binding declares 5.5 against nixpkgs' 6.0
   — check the ABI. Nothing above the front end changes.
2. **Input**, once there is a window to receive it. See the open question.
3. **A leaner logging path.** An app is ~157KB, nearly all Odin runtime pulled in
   by `fmt`. Optimizing halved it; a leaner logging path is the rest.
4. **A compositor**, once more than one process wants the screen. Today `present`
   goes straight to the device and the last frame wins.
5. **Process supervision**, where the mailbox-deadlock question gets settled.
6. **Emulator throughput**, if the boot starts to hurt again. The lever left is a
   TLB in the host.
