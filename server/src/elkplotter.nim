import std/[
  base64,
  httpclient,
  json,
  locks,
  os,
  parsecfg,
  strformat,
  strutils,
  tables,
  tempfiles,
  times,
  unidecode
]
import db_connector/db_sqlite
import mummy, mummy/routers
import webby

type
  PlotterConfig = object
    phonenumber: string
    model: string
    size: string
    prompt: string
    vpypeParams: string
  Plotter = object
    websocket: WebSocket
    config: PlotterConfig
    isRegistered: bool
    isReady: bool
  HttpError = object of IOError

let
  globalConfig = loadConfig("config.ini")
  db = open("elkplotter.db", "", "", "")

var
  L: Lock
  clients: Table[WebSocket, Plotter]
  tlsConfig {.threadvar.}: Config

initLock(L)

template gcSafeWithLock(l: Lock, body: untyped) =
  {.gcsafe.}:
    withLock l:
      body

proc getConfig(): Config =
  if tlsConfig.isNil:
    gcSafeWithLock L:
      tlsConfig = globalConfig
  result = tlsConfig

proc dallE(plotterConf: PlotterConfig, prompt: string): string =
  let
    config = getConfig()
    openAIkey = config.getSectionValue("OpenAI", "apikey")

  let client = newHttpClient()
  client.headers = newHttpHeaders({
    "Authorization": "Bearer " & openAIkey,
    "Content-Type": "application/json"
  })

  let
    data = %*
      { "prompt": prompt
      , "model": plotterConf.model
      , "size": plotterConf.size
      , "n": 1
      , "response_format": "b64_json"
      }
    response = client.post("https://api.openai.com/v1/images/generations", body = $data)

  if not response.code.is2xx:
    raise newException(HttpError,
                       &"Got HTTP {response.code} from OpenAI, body:\n{response.body}")

  let
    respData = response.body.parseJson()
    b64_json = respData["data"][0]["b64_json"]
  result = decode(b64_json.str)

proc vpype(inpath, outpath, params, prompt: string) =
  let
    quoted = quoteShell(prompt)
    asciified = unidecode(quoted)
    formattedParams = params.replace("%prompt%", asciified)
    cmd = fmt"vpype iread {inpath} {formattedParams} write {outpath}"
  discard execShellCmd(cmd)

proc generateImage(plotterConf: PlotterConfig, prompt: string): string =
  let
    prefixedPrompt = plotterConf.prompt & " " & prompt
    image = dallE(plotterConf, prefixedPrompt)

  let (imgfile, inpath) = createTempFile("elkplotter_", "_orig.png")
  imgfile.write(image)
  close imgfile

  let (tracefile, outpath) = createTempFile("elkplotter_", "_traced.svg")
  close tracefile

  vpype(inpath, outpath, plotterConf.vpypeParams, prompt)

  removeFile(inpath)
  result = outpath

proc smsHandler(request: Request) {.gcsafe.} =
  let
    config = getConfig()
    data = request.body.parseSearch()
    fromNumber = data["from"]
    toNumber = data["to"]
    userPrompt = data["message"]
    smsTimestamp = data["created"]
    smsdt = smsTimestamp.parse("yyyy-MM-dd hh:mm:ss'.'ffffff", tz=utc())
    now = now().utc
    timedelta = now - smsdt

  if timedelta > initDuration(minutes=1):
    request.respond(204)
    return

  var plotter: Plotter
  gcSafeWithLock L:
    if clients.len == 0:
      request.respond(204)
      echo "SMS received, but no plotters connected. Message: ", userPrompt
      return
    block findPlotter:
      for ws, pl in clients.mpairs:
        if not pl.isReady:
          continue
        if pl.config.phonenumber != toNumber:
          continue
        pl.isReady = false
        plotter = pl
        break findPlotter
      echo "SMS received, but no vacant plotters. Message: ", userPrompt
      request.respond(200, body = config.getSectionValue("", "sms_response_busy"))
      return

  echo fmt"SMS received, found vacant plotter {plotter}."

  let
    maxReplies = config.getSectionValue("", "max_replies").parseInt()
    replyMaxAge = config.getSectionValue("", "replies_max_age").parseInt()
    replyCutoff = now - initDuration(seconds=replyMaxAge)

  var replies: seq[Row]
  gcSafeWithLock L:
    replies = db.getAllRows(
      sql"SELECT id FROM replies WHERE number = ? AND timestamp >= ?",
      fromNumber, replyCutoff
    )
  if replies.len < maxReplies:
    request.respond(200, body = config.getSectionValue("", "sms_response_ack"))
  else:
    request.respond(204)

  gcSafeWithLock L:
    db.exec(sql"INSERT INTO replies (number, timestamp) VALUES (?, ?)",
            fromNumber, now)

  echo "Generating image for: ", userPrompt
  var
    wsMessage: string
    path: string
  try:
    let promptPrefix = plotter.config.prompt
    path = generateImage(plotter.config, userPrompt)
    let image = path.readFile()
    wsMessage = $(%* {"method": "plot", "params": {"image": image}})
  except CatchableError as e:
    echo "Could not generate image."
    gcSafeWithLock L:
      clients[plotter.websocket].isReady = true
    raise e

  echo "Sending to plotter..."
  plotter.websocket.send(wsMessage)
  removeFile(path)

proc handleRpc(ws: WebSocket, s: string) {.raises: [].} =
  var j: JsonNode
  var rpcMethod: string
  try:
    j = parseJson(s)
  except:
    ws.send("""{"error": "could not parse json"}""")
    return
  try:
    rpcMethod = j["method"].str
  except:
    ws.send("""{"error": "missing key 'method'"}""")
    return
  case rpcMethod
  of "register":
    var config: PlotterConfig
    try:
      config = j["params"].to(PlotterConfig)
    except:
      ws.send("""{"error": "fix your config params"}""")
      return
    gcSafeWithLock L:
      clients.withValue(ws, plotter):
        plotter.config = config
        plotter.isRegistered = true
    try:
      echo fmt"Plotter {ws} registered with: {config}"
    except:
      discard
    ws.send("""{"result": "registered"}""")
  of "ready":
    var res: string
    gcSafeWithLock L:
      clients.withValue(ws, plotter):
        if plotter.isRegistered:
          plotter.isReady = true
          res = """{"result": "readyok"}"""
          try:
            echo fmt"Plotter {ws} is ready."
          except:
            discard
        else:
          res = """{"error": "not registered"}"""
    ws.send(res)
  else:
    ws.send("""{"error": "bad request"}""")

proc upgradeHandler(request: Request) =
  discard request.upgradeToWebSocket()

proc wsHandler(websocket: WebSocket,
               event: WebSocketEvent,
               message: Message) {.gcsafe.} =
  case event
  of OpenEvent:
    echo "Client connected: ", websocket
    gcSafeWithLock L:
      clients[websocket] = Plotter(websocket: websocket, isReady: false)
  of MessageEvent:
    echo message.kind, ": ", message.data
    websocket.handleRpc(message.data)
  of CloseEvent:
    echo "Client disconnected: ", websocket
    gcSafeWithLock L:
      clients.del(websocket)
  of ErrorEvent:
    discard

when isMainModule:
  db.exec(sql"""CREATE TABLE IF NOT EXISTS replies (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  number TEXT,
                  timestamp DATETIME
                )""")
  var router: Router
  router.post("/new-sms", smsHandler)
  router.get("/ws", upgradeHandler)

  let
    hostname = globalConfig.getSectionValue("", "hostname")
    port = globalConfig.getSectionValue("", "port").parseInt()
    server = newServer(router, wsHandler)

  echo fmt"Serving on http://{hostname}:{port}"
  server.serve(Port(port), address = hostname)
