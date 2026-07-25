package kernel

// A ping/pong app, extracted from the kernel to exercise the actor API from the
// outside. Two actors bounce a round counter back and forth as a typed message
// payload; the pinger stops after `limit` rounds and the queue drains.

import emu "../bindings/odin"

// Boot policy: which actors to start. Hardcoded for now -- becomes a launcher
// once apps load from their own ELFs at runtime.
boot :: proc(k: ^Kernel) {
    ping_state := new(PingPongState)
    pong_state := new(PingPongState)

    ping_id := spawn(k, pinger, ping_state)
    pong_id := spawn(k, ponger, pong_state)

    ping_state^ = {peer = pong_id, limit = 3}
    pong_state^ = {peer = ping_id}

    // Kick it off: the pinger sends itself round 0.
    send_value(k, ping_id, ping_id, "start", 0)
}

// Per-actor state: config that persists across messages. The round counter is
// NOT here -- it rides in the message payload, so it flows between the actors.
PingPongState :: struct {
    peer:  ActorId,
    limit: int,
}

pinger :: proc(k: ^Kernel, self: ActorId, msg: Message) {
    s := cast(^PingPongState)k.actors[int(self)].state
    round := message_value(msg, int)

    if round >= s.limit {
        emu.print("pinger: done\n")
        return
    }

    print_round("ping", round)
    send_value(k, self, s.peer, "ping", round)
}

ponger :: proc(k: ^Kernel, self: ActorId, msg: Message) {
    s := cast(^PingPongState)k.actors[int(self)].state
    round := message_value(msg, int)

    print_round("pong", round)
    send_value(k, self, s.peer, "pong", round + 1)
}

print_round :: proc(label: string, n: int) {
    digits := [10]string{"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    emu.print(label)
    emu.print(" ")
    emu.print(digits[n % 10])
    emu.print("\n")
}
