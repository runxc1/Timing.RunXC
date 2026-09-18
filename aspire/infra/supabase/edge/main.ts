// Auto-generated Edge Function Router/Proxy
// DO NOT EDIT - This file is regenerated on each Aspire start
// This router spawns each function as a separate Deno process and proxies requests to it.

const FUNCTIONS_DIR = "/home/deno/functions";
const BASE_PORT = 9100; // Function worker ports start here
const PROXY_PORT = parseInt(Deno.env.get("EDGE_RUNTIME_PORT") || "9000");

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
};

const availableFunctions: string[] = [];

// Track running function workers
const workers: Map<string, { process: Deno.ChildProcess; port: number }> = new Map();
let nextPort = BASE_PORT;

async function startFunctionWorker(functionName: string): Promise<number> {
  const existing = workers.get(functionName);
  if (existing) {
    return existing.port;
  }

  const port = nextPort++;
  const functionPath = FUNCTIONS_DIR + "/" + functionName + "/index.ts";

  console.log("[Router] Starting worker for '" + functionName + "' on port " + port);

  // Read the function file and transform it to use our port
  const functionCode = await Deno.readTextFile(functionPath);

  // Transform the code: replace serve(...) with Deno.serve({ port }, ...)
  // This handles the pattern: serve(async (req) => { ... })
  let transformedCode = functionCode;

  // Replace the serve import with Deno.serve usage
  // Remove the serve import line
  transformedCode = transformedCode.replace(
    /import\s*\{\s*serve\s*\}\s*from\s*["']https:\/\/deno\.land\/std[^"']*\/http\/server\.ts["'];?/g,
    '// serve import removed - using Deno.serve'
  );

  // Replace serve( with Deno.serve({ port: PORT },
  // Negative lookbehind (?<!\.) ensures we don't accidentally match the
  // 'serve' in 'Deno.serve(...)' — functions that already call Deno.serve
  // directly would otherwise become 'Deno.Deno.serve(...)' and crash on start.
  transformedCode = transformedCode.replace(
    /(?<!\.)\bserve\s*\(/g,
    'Deno.serve({ port: ' + port + ' }, '
  );

  // For functions that already use Deno.serve(...), inject the port arg so the
  // worker actually listens on the port the router expects. Matches:
  //   Deno.serve(async (req) => ...   →   Deno.serve({ port: NNNN }, async (req) => ...
  // and only at the start of an arg list (no existing options object).
  transformedCode = transformedCode.replace(
    /Deno\.serve\s*\(\s*(?!\{)/g,
    'Deno.serve({ port: ' + port + ' }, '
  );

  console.log('[Router] Transformed code for ' + functionName);

  const command = new Deno.Command("deno", {
    args: [
      "run",
      "--allow-all",
      "-",  // Read from stdin
    ],
    stdin: "piped",
    stdout: "inherit",
    stderr: "inherit",
    env: Deno.env.toObject(),
  });

  const process = command.spawn();

  // Write the transformed code to stdin
  const writer = process.stdin.getWriter();
  await writer.write(new TextEncoder().encode(transformedCode));
  await writer.close();

  workers.set(functionName, { process, port });

  // Wait for the worker to start
  await new Promise((resolve) => setTimeout(resolve, 2000));

  return port;
}

async function proxyRequest(req: Request, functionName: string, port: number): Promise<Response> {
  const url = new URL(req.url);
  const targetUrl = "http://localhost:" + port + url.pathname + url.search;

  console.log("[Router] Proxying to " + targetUrl);

  try {
    const headers = new Headers(req.headers);

    const proxyReq = new Request(targetUrl, {
      method: req.method,
      headers: headers,
      body: req.body,
      redirect: 'manual',
    });

    const response = await fetch(proxyReq);

    // Add CORS headers to response
    const responseHeaders = new Headers(response.headers);
    Object.entries(corsHeaders).forEach(([k, v]) => responseHeaders.set(k, v));

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: responseHeaders,
    });
  } catch (error) {
    console.error("[Router] Proxy error:", error);
    return new Response(JSON.stringify({ error: 'Proxy error', details: error.message }), {
      status: 502,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
}

console.log("[Router] Starting Edge Function Router on port " + PROXY_PORT);
console.log("[Router] Available functions: " + availableFunctions.join(', '));

Deno.serve({ port: PROXY_PORT }, async (req: Request) => {
  const url = new URL(req.url);
  const path = url.pathname;

  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  // Health check
  if (path === '/health' || path === '/') {
    return new Response(JSON.stringify({
      status: 'ok',
      functions: availableFunctions,
      workers: Array.from(workers.keys()),
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  // Extract function name from path: /functions/v1/{name} or /{name}
  const match = path.match(/^\/(?:functions\/v1\/)?([^\/]+)/);
  const functionName = match?.[1];

  console.log("[Router] Request: " + req.method + " " + path + " -> function: " + functionName);

  if (!functionName) {
    return new Response(JSON.stringify({ error: 'No function specified', available: availableFunctions }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  if (!availableFunctions.includes(functionName)) {
    return new Response(JSON.stringify({ error: 'Function not found: ' + functionName, available: availableFunctions }), {
      status: 404,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  try {
    const port = await startFunctionWorker(functionName);
    return await proxyRequest(req, functionName, port);
  } catch (error) {
    console.error("[Router] Error handling request for '" + functionName + "':", error);
    return new Response(JSON.stringify({ error: error.message || 'Internal error' }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
