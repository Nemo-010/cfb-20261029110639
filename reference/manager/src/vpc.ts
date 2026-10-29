/**
 * The only place in the control plane that calls env.SITE.fetch.
 *
 * vpc_networks binds a whole network, and the destination is a string assembled at runtime.
 * Any route that builds that string from a request body, a query parameter or a value in D1
 * is an SSRF primitive with a route into the private network. So: one function, one static
 * allowlist, no user-supplied host or port.
 *
 * Enforce with a lint rule: `env.SITE.fetch` may appear exactly once in the codebase.
 */

export interface Env {
  SITE: { fetch(input: string, init?: RequestInit): Promise<Response> };
}

type Target = "agent" | "storage";

/**
 * Pinned destinations. Ports are part of the identity, not a parameter.
 *
 * The agent listens on a unix socket on the node and is reached through the tunnel to the
 * site gateway, so a single entry covers every node behind that gateway. If you bind
 * vpc_services instead of vpc_networks you get one entry per host:port and must redeploy the
 * Worker to add a node -- prefer vpc_networks.
 */
const ALLOWED: Record<Target, { host: string; port: number }> = {
  agent: { host: "10.96.0.5", port: 7844 },
  storage: { host: "10.96.0.7", port: 8333 },
};

export class VpcError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly retryable: boolean,
    readonly status = 503,
  ) {
    super(message);
  }
}

/**
 * Fetch through the VPC binding with the destination pinned.
 *
 * `path` must start with "/". It may contain a query string. It may not contain a scheme,
 * an authority, or a ".." segment -- a caller that needs one of those is trying to escape.
 */
export async function vpcFetch(
  env: Env,
  target: Target,
  path: string,
  init?: RequestInit,
): Promise<Response> {
  const t = ALLOWED[target];
  if (!t) throw new VpcError("unknown_target", `no such target: ${target}`, false, 500);

  if (!path.startsWith("/")) {
    throw new VpcError("bad_path", "path must start with /", false, 400);
  }
  // Reject anything that could re-target the request.
  if (path.includes("://") || path.includes("@") || /(^|\/)\.\.(\/|$)/.test(path)) {
    throw new VpcError("bad_path", "path may not contain a scheme, userinfo, or ..", false, 400);
  }

  const url = `http://${t.host}:${t.port}${path}`;

  // Defence in depth: re-parse and assert. URL normalisation is the last place a redirect
  // in the path can turn into a different host.
  const parsed = new URL(url);
  if (parsed.hostname !== t.host || Number(parsed.port) !== t.port) {
    throw new VpcError("bad_path", "normalised destination escaped the allowlist", false, 400);
  }

  let res: Response;
  try {
    res = await env.SITE.fetch(parsed.toString(), init);
  } catch (err) {
    // The VPC path has no stream resumption and a QUIC idle timeout kills in-flight sockets,
    // so a transport error here is normal and always retryable.
    throw new VpcError("vpc_unreachable", String(err), true);
  }

  if (res.status === 401 || res.status === 403) {
    throw new VpcError("fenced", "agent rejected this connection", false, 409);
  }
  if (res.status >= 500) {
    throw new VpcError("agent_error", `agent returned ${res.status}`, true);
  }
  return res;
}

/**
 * JSON convenience wrapper. Caps the body: a Worker has 128 MB and must never buffer a large
 * response. Anything bigger than this belongs in storage behind a presigned URL.
 */
export async function vpcJson<T>(
  env: Env,
  target: Target,
  path: string,
  init?: RequestInit,
  maxBytes = 1 << 20,
): Promise<T> {
  const res = await vpcFetch(env, target, path, init);
  const len = Number(res.headers.get("content-length") ?? "0");
  if (len > maxBytes) {
    throw new VpcError("response_too_large", `${len} bytes exceeds ${maxBytes}`, false, 502);
  }
  return (await res.json()) as T;
}
