// cfbd -- node agent. Structure and protocol types.
//
// This is a skeleton: the types and the lifecycle are real, the tunnel handshake and the
// capability implementations are TODO. It exists so the protocol in spec/agent.md has a
// concrete shape to be reviewed against.
//
// Build: go build ./...
package main

import (
	"context"
	"encoding/binary"
	"errors"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// Protocol (see spec/agent.md)
// ---------------------------------------------------------------------------

type Request struct {
	MsgID      uint64
	Capability string
	Args       []byte
}

type Response struct {
	MsgID uint64
	OK    bool
	Result []byte
	Error *ProtoError
}

type ProtoError struct {
	Code      string
	Message   string
	Retryable bool
}

type StreamFrame struct {
	StreamID uint32
	Seq      uint64
	Payload  []byte
	Window   uint64 // credit granted by the receiver
}

type StateReport struct {
	ConnID       uint64
	Generation   uint64
	Workloads    []WorkloadState
	Capacity     Capacity
	Capabilities []string
}

type WorkloadState struct {
	ID         string
	Generation uint64
	State      string // starting|running|succeeded|failed|stopped
	ExitCode   *int32
	StartedAt  time.Time
	CPUMillis  uint32
	MemoryMiB  uint32
}

type Capacity struct {
	CPUMillis   uint32
	MemoryMiB   uint32
	DiskFreeMiB uint32
}

// Frame is the wire envelope: u32 length, then payload.
func WriteFrame(w interface{ Write([]byte) (int, error) }, payload []byte) error {
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(payload)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

// ---------------------------------------------------------------------------
// Pending-call registry
//
// msg_id correlated request/reply. The important property is not correlation -- it is that
// every waiter is failed with "disconnected" when the connection drops, so a caller gets a
// 200ms error instead of hanging to its timeout.
// ---------------------------------------------------------------------------

var ErrDisconnected = errors.New("disconnected")

type pending struct {
	ch chan Response
}

type broker struct {
	mu    sync.Mutex
	calls map[uint64]*pending
	next  uint64
}

func newBroker() *broker { return &broker{calls: make(map[uint64]*pending)} }

func (b *broker) register() (uint64, *pending) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.next++
	id := b.next
	p := &pending{ch: make(chan Response, 1)}
	b.calls[id] = p
	return id, p
}

func (b *broker) complete(r Response) {
	b.mu.Lock()
	p, ok := b.calls[r.MsgID]
	delete(b.calls, r.MsgID)
	b.mu.Unlock()
	if ok {
		p.ch <- r
	}
}

// failAll is called on disconnect. Every outstanding caller unblocks with an error.
func (b *broker) failAll() {
	b.mu.Lock()
	calls := b.calls
	b.calls = make(map[uint64]*pending)
	b.mu.Unlock()
	for _, p := range calls {
		close(p.ch)
	}
}

func (b *broker) call(ctx context.Context, send func(Request) error, cap string, args []byte) (Response, error) {
	id, p := b.register()
	if err := send(Request{MsgID: id, Capability: cap, Args: args}); err != nil {
		b.mu.Lock()
		delete(b.calls, id)
		b.mu.Unlock()
		return Response{}, err
	}
	select {
	case r, ok := <-p.ch:
		if !ok {
			return Response{}, ErrDisconnected
		}
		return r, nil
	case <-ctx.Done():
		b.mu.Lock()
		delete(b.calls, id)
		b.mu.Unlock()
		return Response{}, ctx.Err()
	}
}

// ---------------------------------------------------------------------------
// Reconnect loop
//
// Listeners and children survive the reconnect. The agent does not restart workloads because
// its control link blipped.
// ---------------------------------------------------------------------------

type Agent struct {
	connID uint64 // monotonic, persisted across restarts
	broker *broker
}

func (a *Agent) Run(ctx context.Context) error {
	backoff := time.Second
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		err := a.connect(ctx)
		a.broker.failAll()
		if err == nil {
			backoff = time.Second
		}

		// 1s doubling to 30s, with jitter.
		jitter := time.Duration(float64(backoff) * 0.2 * (rand64()/float64(1<<63) - 0.5))
		select {
		case <-time.After(backoff + jitter):
		case <-ctx.Done():
			return ctx.Err()
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

// connect establishes one session and blocks until it ends.
//
// TODO: dial the control plane over QUIC/TLS, present the node credential, send the initial
// StateReport, then dispatch frames until the connection dies. A "fenced" response means a
// newer connection owns this node: return a sentinel and exit rather than reconnect.
func (a *Agent) connect(ctx context.Context) error {
	return errors.New("not implemented")
}

func rand64() float64 { return float64(time.Now().UnixNano() % (1 << 62)) }

// ---------------------------------------------------------------------------
// Capabilities
//
// Declared at enrolment and checked locally. The control plane cannot grant itself one the
// agent has not declared.
// ---------------------------------------------------------------------------

type Capability interface {
	Name() string
	Call(ctx context.Context, args []byte) ([]byte, *ProtoError)
}

type registry struct {
	caps map[string]Capability
}

func (r *registry) allowed(name string) bool { _, ok := r.caps[name]; return ok }

func main() {
	// TODO: parse flags (run, status, ps, logs, exec, apply, doctor), load config,
	// install signal handlers that SIGTERM children with a grace period before SIGKILL.
}
