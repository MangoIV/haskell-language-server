// hls-browser.js
// Starts HLS in LSP mode inside the existing dyld/rootfs session and
// connects it to the Monaco editor via MonacoLanguageClient.
// Called once by index.html after `window.editor` and `window.rootfs` are set.

import { MonacoLanguageClient } from "https://esm.sh/monaco-languageclient@9";
import {
  toSocket,
  WebSocketMessageReader,
  WebSocketMessageWriter,
} from "https://cdn.jsdelivr.net/npm/vscode-ws-jsonrpc@3.5.0/+esm";
import { CloseAction, ErrorAction } from "https://esm.sh/vscode-languageclient@9";
import { DyLDBrowserHost, main } from "./dyld.mjs";

// ── LSP framing helpers ────────────────────────────────────────────────────

class LSPDecoder {
  constructor(onMessage) {
    this._buf = new Uint8Array(0);
    this._onMessage = onMessage;
    this._td = new TextDecoder();
    this._te = new TextEncoder();
  }
  push(chunk) {
    const merged = new Uint8Array(this._buf.length + chunk.length);
    merged.set(this._buf);
    merged.set(chunk, this._buf.length);
    this._buf = merged;
    this._drain();
  }
  _drain() {
    const sep = this._te.encode("\r\n\r\n");
    while (true) {
      const headerEnd = this._indexOf(this._buf, sep);
      if (headerEnd === -1) break;
      const header = this._td.decode(this._buf.slice(0, headerEnd));
      const m = header.match(/Content-Length:\s*(\d+)/i);
      if (!m) { this._buf = this._buf.slice(headerEnd + 4); continue; }
      const len = parseInt(m[1], 10);
      const bodyStart = headerEnd + 4;
      if (this._buf.length < bodyStart + len) break;
      this._onMessage(this._td.decode(this._buf.slice(bodyStart, bodyStart + len)));
      this._buf = this._buf.slice(bodyStart + len);
    }
  }
  _indexOf(haystack, needle) {
    outer: for (let i = 0; i <= haystack.length - needle.length; i++) {
      for (let j = 0; j < needle.length; j++) {
        if (haystack[i + j] !== needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

function lspEncode(msg) {
  const te = new TextEncoder();
  const body = te.encode(msg);
  const header = te.encode(`Content-Length: ${body.length}\r\n\r\n`);
  const out = new Uint8Array(header.length + body.length);
  out.set(header);
  out.set(body, header.length);
  return out;
}

// ── Main export ────────────────────────────────────────────────────────────

export async function startHLS({ rootfs, dotEl, textEl }) {
  function setStatus(state, label) {
    dotEl.className = "hls-dot " + state;
    textEl.textContent = label;
  }

  setStatus("connecting", "HLS starting")

  // stdin pipe: we push encoded LSP frames in; HLS reads them
  let hlsStdinController = null;
  const hlsStdinStream = new ReadableStream({ start(c) { hlsStdinController = c; } });

  // Listeners called when HLS stdout produces a decoded JSON message
  const messageListeners = [];

  const decoder = new LSPDecoder((jsonStr) =>
    messageListeners.forEach((fn) => fn(jsonStr))
  );

  let hlsDyld;
  try {
    hlsDyld = await main({
      rpc: new DyLDBrowserHost({
        rootfs,
        stdout: (chunk) =>
          decoder.push(
            typeof chunk === "string" ? new TextEncoder().encode(chunk) : chunk
          ),
        stderr: (msg) => console.debug("[HLS]", msg),
        stdin: hlsStdinStream,
      }),
      searchDirs: [
        "/tmp/clib",
        "/tmp/hslib/lib/wasm32-wasi-ghc-9.15.20251024",
      ],
      mainSoPath: "/tmp/hls.so",
      args: ["hls.so", "--lsp"],
      isIserv: false,
    });
    setStatus("ready", "HLS ready");
  } catch (e) {
    console.error("HLS failed to start", e);
    setStatus("error", "HLS error");
    return;
  }

  // Fake WebSocket bridging vscode-ws-jsonrpc ↔ HLS stdio
  class HLSSocket extends EventTarget {
    constructor() {
      super();
      this.readyState = WebSocket.OPEN;
    }
    send(data) {
      hlsStdinController?.enqueue(lspEncode(data));
    }
    addEventListener(type, fn, ...rest) {
      if (type === "message") messageListeners.push((s) => fn({ data: s }));
      super.addEventListener(type, fn, ...rest);
    }
    close() { this.readyState = WebSocket.CLOSED; }
  }

  const socket = new HLSSocket();
  const wsSocket = toSocket(socket);
  const reader = new WebSocketMessageReader(wsSocket);
  const writer = new WebSocketMessageWriter(wsSocket);

  new MonacoLanguageClient({
    name: "Haskell Language Server",
    clientOptions: {
      documentSelector: [{ language: "haskell" }],
      errorHandler: {
        error:  () => ({ action: ErrorAction.Continue }),
        closed: () => ({ action: CloseAction.DoNotRestart }),
      },
      workspaceFolder: {
        uri: window.monaco.Uri.parse("file:///tmp"),
        name: "playground",
        index: 0,
      },
    },
    connectionProvider: { get: async () => ({ reader, writer }) },
  }).start();
}
