/**
 * NodeDO -- one Durable Object per node.
 *
 * Holds the live connection state, the open streams and the log fanout. Deliberately NOT the
 * job ledger: that is D1, written on transition only. DO duration bills a flat 128 MB
 * allocation regardless of use, and SQLite rows written cost $1.00/million -- a row per log
 * line is 120k rows for a 40-minute build.
 *
 * The two things this class exists to get right:
 *   1. connection fencing -- a reconnecting agent must evict its predecessor, or two agents
 *      both reconcile and a workload starts twice;
 *   2. generation-based reconcile -- push only when the agent is behind.
 */

export interface Env {
  DB: D1Database;
  SITE: { fetch(input: string, init?: RequestInit): Promise<Response> };
}

interface StateReport {
  connId: number;
  generation: number;
  workloads: Array<{
    id: string;
    generation: number;
    state: "starting" | "running" | "succeeded" | "failed" | "stopped";
    exitCode?: number;
    memoryMib?: number;
  }>;
  capacity: { cpuMillis: number; memoryMib: number; diskFreeMib: number };
  capabilities: string[];
}

interface NodeRecord {
  connId: number;
  generation: number;
  lastSeen: number;
  capabilities: string[];
}

export class NodeDO implements DurableObject {
  private state: DurableObjectState;
  private env: Env;
  private sockets = new Set<WebSocket>();
  private streams = new Map<number, { kind: string; buffer: string[]; cursor: number }>();

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    switch (url.pathname) {
      case "/connect":
        return this.onConnect(request);
      case "/report":
        return this.onReport(request);
      case "/logs":
        return this.onLogs(url.searchParams.get("cursor") ?? "0");
      case "/health":
        return Response.json(await this.record());
      default:
        return new Response("not found", { status: 404 });
    }
  }

  // ---- connection -------------------------------------------------------

  /**
   * Fence, then accept.
   *
   * The new connId is claimed in the same storage write that records the connection, so the
   * predecessor's next call sees a newer connId and exits. Without this, a network partition
   * leaves two agents that both believe they own the node.
   */
  private async onConnect(request: Request): Promise<Response> {
    const incoming = Number(request.headers.get("x-conn-id"));
    if (!Number.isSafeInteger(incoming) || incoming <= 0) {
      return Response.json({ code: "bad_conn_id", retryable: false }, { status: 400 });
    }

    const prev = await this.state.storage.get<NodeRecord>("node");
    if (prev && prev.connId > incoming) {
      // A newer connection already owns this node. Refuse, and tell the agent to exit.
      return Response.json({ code: "fenced", retryable: false }, { status: 409 });
    }

    await this.state.storage.put<NodeRecord>("node", {
      connId: incoming,
      generation: prev?.generation ?? 0,
      lastSeen: Date.now(),
      capabilities: prev?.capabilities ?? [],
    });

    // Close any socket from the predecessor so it cannot keep streaming.
    for (const ws of this.sockets) {
      try { ws.close(4001, "fenced"); } catch { /* already closed */ }
    }
    this.sockets.clear();

    const { 0: client, 1: server } = new WebSocketPair();
    server.accept();
    this.sockets.add(server);
    server.addEventListener("close", () => this.sockets.delete(server));

    return new Response(null, { status: 101, webSocket: client });
  }

  // ---- reconcile --------------------------------------------------------

  /**
   * Apply a state report: correct D1 to match reality, then push only what is behind.
   *
   * Reality wins. D1 holds intent; when they disagree the agent is right about what is
   * running, and the control plane is right about what should be.
   */
  private async onReport(request: Request): Promise<Response> {
    const report = (await request.json()) as StateReport;
    const rec = await this.record();

    if (rec.connId !== report.connId) {
      return Response.json({ code: "fenced", retryable: false }, { status: 409 });
    }

    await this.state.storage.put<NodeRecord>("node", {
      ...rec,
      generation: report.generation,
      lastSeen: Date.now(),
      capabilities: report.capabilities,
    });

    // Correct D1 for every workload the agent reports.
    const stmt = this.env.DB.prepare(
      `UPDATE workloads
          SET state = ?, exit_code = ?, updated_at = ?
        WHERE id = ? AND generation <= ?`,
    );
    const batch = report.workloads.map((w) =>
      stmt.bind(w.state, w.exitCode ?? null, Date.now(), w.id, w.generation),
    );
    if (batch.length) await this.env.DB.batch(batch);

    // Push only the workloads whose desired generation is ahead of what the agent applied.
    const behind = await this.env.DB.prepare(
      `SELECT id, spec, generation FROM workloads
        WHERE node_id = ? AND generation > ? AND state NOT IN ('succeeded','stopped')`,
    )
      .bind(this.id(), report.generation)
      .all<{ id: string; spec: string; generation: number }>();

    for (const w of behind.results ?? []) {
      await this.push(w.id, JSON.parse(w.spec), w.generation);
    }

    return Response.json({ applied: report.generation, pushed: behind.results?.length ?? 0 });
  }

  private async push(id: string, spec: unknown, generation: number) {
    // Applying the same (id, generation) twice must be a no-op on the agent side.
    await this.state.storage.put(`pending:${id}`, { spec, generation });
  }

  // ---- logs -------------------------------------------------------------

  /**
   * Cursor-based SSE. The VPC path has no stream resumption, so a consumer reconnects with a
   * cursor rather than resuming a broken stream.
   */
  private async onLogs(cursorRaw: string): Promise<Response> {
    const cursor = Number(cursorRaw) || 0;
    const stream = this.streams.get(1) ?? { kind: "log", buffer: [], cursor: 0 };

    const body = new ReadableStream({
      start: (controller) => {
        const enc = new TextEncoder();
        for (const [i, line] of stream.buffer.entries()) {
          if (i < cursor) continue;
          controller.enqueue(enc.encode(`id: ${i}\ndata: ${line}\n\n`));
        }
        controller.close();
      },
    });

    return new Response(body, {
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-store",
      },
    });
  }

  // ---- helpers ----------------------------------------------------------

  private async record(): Promise<NodeRecord> {
    return (
      (await this.state.storage.get<NodeRecord>("node")) ?? {
        connId: 0,
        generation: 0,
        lastSeen: 0,
        capabilities: [],
      }
    );
  }

  private id(): string {
    return this.state.id.toString();
  }
}
